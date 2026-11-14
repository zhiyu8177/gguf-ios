import Foundation
import AVFoundation

/// 曲库单曲（index 是电脑端 /library 的顺序号，resolve 用它取流钥匙）
struct Track: Identifiable, Equatable {
    let index: Int
    let name: String
    let rel: String
    var id: Int { index }
}

/// 手机端音乐播放：曲库拉取 + /resolve 取钥匙 + AVPlayer 拉流
/// 声音只在手机出，电脑不播放（resolve 不触发电脑端播放器）。
final class MusicVM: ObservableObject {

    /// 【2026-11-14 聊天点歌桥】全局实例：聊天回复里的 [music:key=..] 由它播放，
    /// 不依赖音乐页是否打开（AVPlayer 后台照样出声）。
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
    /// 播完自动随机下一首
    @Published var autoNext = true
    /// 【2026-11-14 聊天点歌桥】连播池过滤：聊天里点“有人声”时电脑端会标 src=ccMixter，
    /// 播完接的下一首就只从该子库摇，不然 4480 首里八成是器乐，一句人声都没了
    var autoNextFilter: String? = nil

    private var player: AVPlayer?
    private var endObs: NSObjectProtocol?
    private var musicBase = ""                 // http://<电脑host>:8321
    private let serverProvider: () -> String   // 实时取 ChatVM.server（地址可改）

    init(serverProvider: @escaping () -> String) {
        self.serverProvider = serverProvider
    }

    deinit {
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
    }

    /// 从 8099 地址推音乐服务地址：同主机、换 8321 端口
    static func musicBase(from server: String) -> String {
        guard let u = URL(string: server), let host = u.host else { return "" }
        return "http://" + host + ":8321"
    }

    var filtered: [Track] {
        let k = filter.trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return tracks }
        return tracks.filter { $0.name.localizedCaseInsensitiveContains(k) }
    }

    // MARK: - 曲库

    func reload() {
        let base = MusicVM.musicBase(from: serverProvider())
        guard !base.isEmpty else {
            loaded = false; lastError = "电脑地址不对，先在设置里改"; return
        }
        musicBase = base
        guard let url = URL(string: base + "/library?limit=8000") else { return }   // 曲库已 4480 首，原来 4000 会截断
        loading = true
        lastError = ""
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
                    self.lastError = "连不上电脑音乐服务（8321 端口）"
                    return
                }
                self.tracks = items.compactMap {
                    guard let idx = $0["index"] as? Int,
                          let name = $0["name"] as? String,
                          let rel = $0["rel"] as? String else { return nil }
                    return Track(index: idx, name: name, rel: rel)
                }
                self.loaded = self.tracks.isEmpty ? false : true
                if self.tracks.isEmpty { self.lastError = "曲库是空的" }
            }
        }.resume()
    }

    // MARK: - 播放

    /// 点歌：resolve（纯数字 index，避开中文路径编码）拿钥匙 → AVPlayer 拉流
    func play(_ t: Track) {
        if musicBase.isEmpty { musicBase = MusicVM.musicBase(from: serverProvider()) }
        guard !musicBase.isEmpty, let url = URL(string: musicBase + "/resolve?i=" + String(t.index)) else {
            lastError = "电脑地址不对"; return
        }
        loading = true
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                guard let d = data,
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      (obj["ok"] as? Bool) == true,
                      let key = obj["key"] as? String,
                      let title = obj["title"] as? String else {
                    self.lastError = "取流失败：电脑上没这首歌了？"
                    return
                }
                self.startStream(self.musicBase + "/stream?k=" + key, title: title)
            }
        }.resume()
    }

    /// 随机来一首（排除当前这首；带连播池过滤时只在该子库里摇）
    func playRandom() {
        var pool = tracks
        if let f = autoNextFilter {
            let sub = pool.filter { $0.rel.localizedCaseInsensitiveContains(f) }
            if !sub.isEmpty { pool = sub }
        }
        guard !pool.isEmpty else { lastError = "曲库还没加载"; return }
        var t = pool.randomElement()!
        if pool.count > 1, t.name == nowTitle {
            while t.name == nowTitle { t = pool.randomElement()! }
        }
        play(t)
    }

    /// 【2026-11-14 聊天点歌桥】直接用电脑端硬通道给的流钥匙开播，不用再 resolve。
    /// 聊天页说“放有人声歌曲”→ 电脑端回 [music:key=..|src=..|title=..] → 这里接手。
    func playKey(_ key: String, title: String, filter: String?) {
        if musicBase.isEmpty { musicBase = MusicVM.musicBase(from: serverProvider()) }
        guard !musicBase.isEmpty else { lastError = "电脑地址不对"; return }
        if let f = filter, !f.isEmpty, f != "all" { autoNextFilter = f } else { autoNextFilter = nil }
        // 曲库没拉过就连播接不上（播完 playRandom 靠 tracks），后台先拉一把
        if tracks.isEmpty { reload() }
        startStream(musicBase + "/stream?k=" + key, title: title)
    }

    /// 解析电脑端硬通道附在回复尾部的标记，返回（去掉标记的正文, key, title, src）。
    /// 格式：[music:key=881c080010|src=ccMixter|title=Vidian - The Reaper.mp3]
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

    /// 播放/暂停切换
    func toggle() {
        guard player != nil, !nowTitle.isEmpty else { return playRandom() }
        if playing { player?.pause(); playing = false }
        else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play(); playing = true
        }
    }

    func stop() {
        player?.pause()
        player = nil
        playing = false
    }

    private func startStream(_ urlStr: String, title: String) {
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        guard let url = URL(string: urlStr) else { lastError = "流地址不对"; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { }
        let p = AVPlayer(url: url)
        player = p
        nowTitle = title
        playing = true
        lastError = ""
        p.play()
        // 播完自动接下一首（连播开关关了就停在原地）
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.autoNext { self.playRandom() }
            else { self.playing = false }
        }
    }
}
