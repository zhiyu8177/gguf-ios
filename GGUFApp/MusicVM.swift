import Foundation
import AVFoundation

/// 曲库单曲（index 是电脑端 /library 的顺序号，resolve 用它取流钥匙）
struct Track: Identifiable, Equatable {
    let index: Int
    let name: String
    let rel: String
    var id: Int { index }
}

/// 播放状态机。界面必须能一眼看出卡在哪一步，
/// 不再出现"看不见、听不见、也不知道为什么"的黑箱。
enum MusicState: Equatable {
    case idle
    case loading(String)      // 取流中 / 缓冲中
    case playing
    case paused
    case failed(String)

    var text: String {
        switch self {
        case .idle:            return "未播放"
        case .loading(let s):  return s
        case .playing:         return "正在播放"
        case .paused:          return "已暂停"
        case .failed(let s):   return s
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

/// 【2026-11-14 v3 重写】手机端音乐播放。
///
/// 与旧版的根本差别：
/// 1. 播放不再依赖聊天文本里的 [music:key=..] 标记——旧方案要等电脑把标记塞进
///    回复、手机再解析，任何一环掉链子就无声且没有任何提示。现在手机自己查曲库
///    （/library → 过滤子库 → /resolve 拿钥匙 → /stream 拉流），链路全部现成且已验证。
/// 2. 音频会话在 App 启动时就 setCategory(.playback)+setActive，不再等播放瞬间才激活，
///    避免激活失败被静默吞掉。
/// 3. 全程状态可见：取流失败/钥匙过期/缓冲卡住/12 秒不出声，都变成界面上一句话。
/// 4. 播放前顺手让电脑闭嘴（/stop），声音只从手机出。
final class MusicVM: ObservableObject {

    static let shared = MusicVM(serverProvider: { MusicVM.globalServer })
    /// ChatVM 每次改地址时同步过来（shared 实例拿不到 ChatVM 的闭包）
    static var globalServer = ""

    @Published private(set) var tracks: [Track] = []
    @Published var filter: String = ""
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var lastError = ""
    @Published private(set) var nowTitle = ""
    @Published private(set) var playing = false
    @Published private(set) var state: MusicState = .idle
    /// 播完自动随机下一首
    @Published var autoNext = true
    /// 连播池过滤（聊天里点"有人声"时只在该子库摇）
    var autoNextFilter: String? = nil

    private var player: AVPlayer?
    private var itemObs: [NSKeyValueObservation] = []
    private var endObs: NSObjectProtocol?
    private var interruptionObs: NSObjectProtocol?
    private var stallTimer: DispatchWorkItem?
    private var musicBase = ""
    private let serverProvider: () -> String
    private var loadedAt = Date.distantPast
    /// 最近播过的歌名：随机点歌时避开，别连着放同一首
    private var recent: [String] = []
    /// 递增序号：旧请求的异步回调不许覆盖新一轮的状态
    private var seq = 0

    init(serverProvider: @escaping () -> String) {
        self.serverProvider = serverProvider
        MusicVM.prepareSession()
        interruptionObs = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                let optRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume),
                   self.player != nil {
                    MusicVM.prepareSession()
                    self.player?.play()
                    self.setState(.playing)
                }
            }
        }
    }

    deinit {
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        if let o = interruptionObs { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - 音频会话

    /// App 启动即调用一次：把会话设成 .playback（忽略静音拨片）+ 激活。
    /// 放在播放瞬间才做的话，一旦被系统拒绝（来电、录音占用）整轮就静默失败。
    static func prepareSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setActive(true, options: [])
        } catch {
            // 不抛给界面：播放时会再试一次，真失败会由 AVPlayer 状态暴露
        }
    }

    /// 电脑侧地址 → 音乐服务地址（同主机，换 8321）
    static func musicBase(from server: String) -> String {
        guard let u = URL(string: server), let host = u.host else { return "" }
        return "http://" + host + ":8321"
    }

    private func base() -> String {
        if musicBase.isEmpty { musicBase = MusicVM.musicBase(from: serverProvider()) }
        return musicBase
    }

    var filtered: [Track] {
        let k = filter.trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return tracks }
        return tracks.filter { $0.name.localizedCaseInsensitiveContains(k) }
    }

    // MARK: - 曲库

    func reload(completion: (() -> Void)? = nil) {
        let b = base()
        guard !b.isEmpty else {
            loaded = false
            setFailed("电脑地址不对：右上角齿轮改地址")
            completion?()
            return
        }
        guard let url = URL(string: b + "/library?limit=8000") else { return }
        loading = true
        if !state.isFailed { lastError = "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                guard let d = data, err == nil,
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      (obj["ok"] as? Bool) == true,
                      let items = obj["items"] as? [[String: Any]] else {
                    self.loaded = false
                    self.setFailed("连不上电脑音乐服务（8321）：" + (err?.localizedDescription ?? "无响应"))
                    completion?()
                    return
                }
                self.tracks = items.compactMap {
                    guard let idx = $0["index"] as? Int,
                          let name = $0["name"] as? String,
                          let rel = $0["rel"] as? String else { return nil }
                    return Track(index: idx, name: name, rel: rel)
                }
                self.loaded = !self.tracks.isEmpty
                self.loadedAt = Date()
                if self.tracks.isEmpty { self.setFailed("曲库是空的") }
                else if self.state.isFailed { self.state = .idle }   // 拉库成功，清掉旧报错
                completion?()
            }
        }.resume()
    }

    /// 曲库超过 10 分钟就当过期（电脑端可能在加歌）
    private func ensureLibrary(_ done: @escaping () -> Void) {
        if tracks.isEmpty || Date().timeIntervalSince(loadedAt) > 600 {
            reload(completion: done)
        } else {
            done()
        }
    }

    // MARK: - 播放（对外入口）

    /// 点列表里的某一首：resolve 拿钥匙 → 拉流
    func play(_ t: Track) {
        let b = base()
        guard !b.isEmpty else { setFailed("电脑地址不对：右上角齿轮改地址"); return }
        guard let url = URL(string: b + "/resolve?i=" + String(t.index)) else { return }
        loading = true
        seq += 1
        let my = seq
        setState(.loading("取流中…"), title: t.name)
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self = self, self.seq == my else { return }
                self.loading = false
                guard let d = data, err == nil,
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      (obj["ok"] as? Bool) == true,
                      let key = obj["key"] as? String,
                      let title = obj["title"] as? String, !key.isEmpty else {
                    let msg = ((try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any])?["error"] as? String
                    self.setFailed("取流失败：" + (msg ?? err?.localizedDescription ?? "电脑没响应"))
                    return
                }
                self.startStream(b + "/stream?k=" + key, title: title)
            }
        }.resume()
    }

    /// 随机来一首（连播开关、骰子按钮、说话点歌都走这里）
    func playRandom() {
        var pool = tracks
        if let f = autoNextFilter, !f.isEmpty, f != "all" {
            let sub = pool.filter { $0.rel.localizedCaseInsensitiveContains(f) }
            if !sub.isEmpty { pool = sub }
        }
        pickAndPlay(pool)
    }

    /// 【v3 核心】说话点歌：手机自己从曲库挑一首放，完全不经过聊天文本标记。
    /// - vocalOnly: 只要有人声的歌（ccMixter 子库）
    /// - hint: 电脑回复原文。回复里常写"开始连播：<歌名>"，能在曲库里对上就直接放那首，
    ///   免得聊天说的是一首、手机放的是另一首。对不上就回落到子库随机。
    func playLibrary(vocalOnly: Bool, hint: String? = nil) {
        ensureLibrary { [weak self] in
            guard let self = self else { return }
            guard !self.tracks.isEmpty else {
                self.setFailed("曲库拉不到，手机上不了 8321")
                return
            }
            var pool = self.tracks
            if vocalOnly {
                let sub = pool.filter {
                    $0.rel.localizedCaseInsensitiveContains("ccmixter") ||
                    $0.name.localizedCaseInsensitiveContains("ccmixter")
                }
                if !sub.isEmpty { pool = sub }
                self.autoNextFilter = "ccMixter"      // 播完接的下一首也在人声库里摇
            } else {
                self.autoNextFilter = nil
            }
            // 先按回复里提到的歌名对号入座
            if let h = hint, h.count > 4,
               let hit = self.tracks.first(where: { t in
                   let base = (t.name as NSString).deletingPathExtension
                   return base.count > 3 && h.contains(base)
               }) {
                self.recent.append(hit.name)
                if self.recent.count > 6 { self.recent.removeFirst() }
                self.play(hit)
                return
            }
            self.pickAndPlay(pool)
        }
    }

    private func pickAndPlay(_ pool: [Track]) {
        guard !pool.isEmpty else { setFailed("曲库还没加载好，进音乐页重试一下"); return }
        var cand = pool
        if pool.count > recent.count {
            let fresh = pool.filter { !recent.contains($0.name) }
            if !fresh.isEmpty { cand = fresh }
        }
        let pick = cand.randomElement()!
        recent.append(pick.name)
        if recent.count > 6 { recent.removeFirst() }
        play(pick)
    }

    /// 兼容老接口：拿到电脑给的钥匙直接拉流（聊天标记 / 调试用）
    func playKey(_ key: String, title: String, filter: String?) {
        let b = base()
        guard !b.isEmpty else { setFailed("电脑地址不对"); return }
        if let f = filter, !f.isEmpty, f != "all" { autoNextFilter = f } else { autoNextFilter = nil }
        ensureLibrary { }
        startStream(b + "/stream?k=" + key, title: title)
    }

    /// 解析电脑端老版本附在回复尾部的标记，返回（去掉标记的正文, key, title, src）。
    /// v3 起播放不再靠它，只用来把标记从显示文本里剥干净。
    static func parseMusicTag(_ text: String) -> (cleaned: String, key: String, title: String, src: String?)? {
        guard let start = text.range(of: "[music:key=") else { return nil }
        guard let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else { return nil }
        let body = String(text[start.upperBound..<end.lowerBound])
        var key = "", title = "", src: String? = nil
        for part in body.split(separator: "|") {
            let kv = part.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == "=" }
            guard kv.count == 2 else { continue }
            switch String(kv[0]) {
            case "key": key = String(kv[1])
            case "title": title = String(kv[1])
            case "src": src = String(kv[1])
            default: break
            }
        }
        guard !key.isEmpty else { return nil }
        var cleaned = text
        cleaned.removeSubrange(start.lowerBound...end.lowerBound)
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), key, title, src)
    }

    // MARK: - 播放控制

    func toggle() {
        guard let p = player else { playRandom(); return }
        if playing {
            p.pause()
            playing = false
            state = .paused
        } else {
            MusicVM.prepareSession()
            p.play()
            playing = true
            state = .playing
        }
    }

    func stop() {
        seq += 1
        teardown()
        playing = false
        nowTitle = ""
        state = .idle
        lastError = ""
    }

    /// 下一首（连播开关关着也照放，手动点的就是"我要听下一首"）
    func next() { playRandom() }

    // MARK: - 拉流

    private func startStream(_ urlStr: String, title: String) {
        MusicVM.prepareSession()
        teardown()
        seq += 1
        let my = seq
        guard let url = URL(string: urlStr) else { setFailed("流地址不对"); return }
        nowTitle = title
        setState(.loading("缓冲中…"), title: title)

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p

        itemObs = [
            item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
                DispatchQueue.main.async {
                    guard let self = self, self.seq == my else { return }
                    switch it.status {
                    case .readyToPlay: self.setState(.playing)
                    case .failed:
                        let e = it.error?.localizedDescription ?? "未知（可能流钥匙过期）"
                        self.setFailed("音频加载失败：" + e)
                    default: break
                    }
                }
            },
            p.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
                DispatchQueue.main.async {
                    guard let self = self, self.seq == my else { return }
                    switch pl.timeControlStatus {
                    case .playing:
                        self.setState(.playing)
                    case .waitingToPlayAtSpecifiedRate:
                        if !self.state.isFailed { self.setState(.loading("缓冲中…")) }
                    default: break
                    }
                }
            }
        ]

        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.seq == my else { return }
            if self.autoNext { self.playRandom() } else {
                self.playing = false
                self.state = .paused
            }
        }

        // 15 秒还没出声：把"卡在哪"直接写在界面上，用户不用猜
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.seq == my else { return }
            if self.state != .playing {
                self.setFailed("15 秒没出声：检查手机静音拨片/音量，或点顶部 🔊 测手机音频")
            }
        }
        stallTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)

        p.play()
        silenceComputer()
    }

    /// 声音只从手机出：让电脑侧播放器闭嘴（不影响已发出的流钥匙）
    private func silenceComputer() {
        let b = base()
        guard !b.isEmpty, let url = URL(string: b + "/stop") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    private func teardown() {
        stallTimer?.cancel()
        stallTimer = nil
        itemObs.forEach { $0.invalidate() }
        itemObs.removeAll()
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = nil
        player?.pause()
        player = nil
    }

    // MARK: - 状态

    private func setState(_ s: MusicState, title: String? = nil) {
        state = s
        if let t = title { nowTitle = t }
        switch s {
        case .playing:
            playing = true
            lastError = ""
        case .paused:
            playing = false
        case .failed(let msg):
            playing = false
            lastError = msg
        default:
            playing = false
        }
    }

    private func setFailed(_ msg: String) {
        setState(.failed(msg))
    }

    // MARK: - 手机音频自检

    /// 放一声 440Hz 短音：听到 = 会话/输出正常，问题在网络；
    /// 听不到 = 静音拨片、音量 0、或蓝牙连着别的设备。
    static func testTone() {
        prepareSession()
        let sr = 44100.0
        let n = Int(sr * 0.7)
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let env = min(1.0, Double(i) / (sr * 0.02)) * min(1.0, Double(n - i) / (sr * 0.12))
            samples[i] = Int16(sin(2.0 * .pi * 440.0 * Double(i) / sr) * 11000.0 * env)
        }
        var d = Data()
        let bytes = UInt32(n * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { bp in
            d.append(UnsafeRawPointer(bp.baseAddress!).assumingMemoryBound(to: UInt8.self), count: n * 2)
        }
        do {
            let p = try AVAudioPlayer(data: d)
            p.volume = 1.0
            p.play()
            testPlayer = p          // 保住引用，否则立刻被释放
        } catch { }
    }

    private static var testPlayer: AVAudioPlayer?
}
