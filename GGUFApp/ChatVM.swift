import Foundation
import Combine
import AVFoundation

struct Msg: Identifiable, Equatable {
    enum Role { case user, ai, sys }
    let id = UUID()
    var role: Role
    var text: String
    var streaming: Bool = false
}

/// 全部状态与网络逻辑（原生，无网页层）
final class ChatVM: ObservableObject {

    @Published var msgs: [Msg] = [Msg(role: .sys, text: "[ 手机直连 AgentShell · 原生界面 ]")]
    @Published var input: String = ""
    @Published var busy = false
    @Published var voiceMode = false
    @Published var engineOK = false
    @Published var ttsOK = false
    @Published var autoRead = true
    /// 一轮回答完成回调（通话模式用）：参数为最终回答文本，空串 = 失败/无内容
    var onReplyDone: ((String) -> Void)?
    @Published private(set) var server: String

    private var sse: SSEClient?
    private var timer: Timer?
    private var pollTimer: Timer?
    private var pollID: UInt64 = 0
    private var pollFails = 0
    /// 待探测的服务地址队列（只在主线程读写）
    private var probeQueue: [String] = []
    /// 是否正在跑一轮探测，防定时器叠加
    private var probing = false
    /// 刚探不通的地址：外网状态下每 5 秒白等 6 秒超时太浪费，记下来 2 分钟内先跳过
    private var deadUntil: [String: Date] = [:]
    /// 本轮轮询的起等时间
    private var pollStartedAt: Date?
    /// 【v3】本轮是否已处理过音乐（每轮 send 重置，防 poll 重复触发）
    private var musicFired = false
    /// 【v3】本轮用户话里的音乐意图（send 时解析；手机据此自己点歌，不依赖电脑标记）
    private var wantMusic = false
    private var wantVocal = false
    private var wantStopMusic = false
    /// 【v4】用户点名的歌名（"放安和桥"）；曲库没有就跳酷狗搜
    private var wantSong: String? = nil
    private var player: AVAudioPlayer?

    /// 【2026-11-18 适配 35B 部署】电脑局域网 IP 会变，旧默认 172.16.2.103 已不在本机网卡上，
    /// 健康检查失败就顺着候选列表往下试，试通哪个就钉住哪个 —— 换网/换机器不用再重打壳。
    static let candidates = [
        "http://192.168.137.72:8099", // 手机热点/同一局域网：内网直连，最快（看片走这条才不卡）
        "http://172.16.3.222:8099",   // 蒲公英 VPN：人在外面才走这条，经 Oray 中转，比内网慢
        "http://192.168.1.7:8099",    // 旧无线地址（留作备用）
        "http://172.16.2.248:8099",   // 以太网 2（当前不通，留作备用）
    ]
    static let defaultServer = candidates[0]

    /// 地址统一收口：去空格、补 http://、去结尾多余的斜杠。
    /// 2026-11-18 实测：地址带尾斜杠时 /health 返回 404，壳会一直两个红灯，
    /// 用户完全看不出是自己多打了一个"/"。
    static func normalize(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return v }
        if !v.hasPrefix("http://") && !v.hasPrefix("https://") { v = "http://" + v }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }
    private static let serverKey = "wuj_server_v3"   // 换 key：老包里存的失效地址不再生效

    /// 电脑端偶尔会把"工具调用"直接写成正文（35B 在工具链中途崩的时候，
    /// 会吐 `[{"type":"run_command","command":"…"}]` 这种裸 JSON）。这不该当回答留在屏幕上，
    /// 否则用户看到的是一堆乱码，还以为壳坏了。
    static let toolCallHint = "[电脑把工具调用写成了文本，这一轮没执行成功，重发一次试试]"
    static func looksLikeToolCall(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 2000 else { return false }
        if s.hasPrefix("<tool_call>") || s.hasPrefix("<tools>") { return true }
        if s.hasPrefix("[{") || s.hasPrefix("{") {
            let marks = ["\"type\"", "\"name\"", "\"function\"", "\"arguments\""]
            return marks.contains { s.contains($0) }
        }
        return false
    }

    init() {
        let s = UserDefaults.standard.string(forKey: ChatVM.serverKey) ?? ""
        server = s.isEmpty ? ChatVM.defaultServer : ChatVM.normalize(s)
        MusicVM.globalServer = server          // 播放器要拿 8321 地址
        MusicVM.prepareSession()               // 启动就把音频会话备好
    }

    deinit { timer?.invalidate(); pollTimer?.invalidate() }

    // MARK: - 服务地址

    func saveServer(_ s: String) {
        let v = ChatVM.normalize(s)            // 去空格 / 补 http:// / 去掉结尾斜杠
        guard !v.isEmpty else { return }
        server = v
        MusicVM.globalServer = v               // 聊天点歌桥：地址改了同步给 MusicVM.shared
        UserDefaults.standard.set(v, forKey: ChatVM.serverKey)
        checkHealth()
    }

    // MARK: - 生命周期

    func start() {
        checkHealth()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    // MARK: - 健康检查

    func checkHealth() {
        guard !probing else { return }        // 上一轮还没探完就别叠上去（4 个地址最坏 24 秒）
        probing = true
        // 【v2.8 内网优先】按候选表顺序依次探，内网地址排第一：在家/同热点就直接钉内网，
        // 只有内网探不通（人在外面）才落到蒲公英。当前地址不在表里时放最后兜底。
        var q = ChatVM.candidates
        if !q.contains(server) { q.append(server) }
        probeQueue = q
        probeNext()
    }

    /// 顺着候选地址探测：按表顺序（内网在前）试，第一个探通的就钉住并落盘；
    /// 全都不通才熄灭两个状态灯。
    private func probeNext() {
        guard !probeQueue.isEmpty else {
            probing = false
            engineOK = false; ttsOK = false
            return
        }
        let base = probeQueue.removeFirst()
        // 内网地址刚探失败过（说明人在外面），2 分钟内先跳过；正在用的地址不跳过
        if base != server, let until = deadUntil[base], until > Date() {
            probeNext()
            return
        }
        guard let url = URL(string: base + "/health") else {
            probeNext()
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            var e = false, t = false, model = ""
            if let d = data, err == nil,
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                let eng = obj["engine"] as? String ?? ""
                e = (eng == "online" || eng == "standby")
                t = (obj["tts"] as? Bool) ?? false
                model = obj["model"] as? String ?? ""
            }
            DispatchQueue.main.async {
                if e {
                    self.probing = false
                    self.deadUntil.removeValue(forKey: base)
                    if base != self.server {
                        self.server = base
                        MusicVM.globalServer = base
                        UserDefaults.standard.set(base, forKey: ChatVM.serverKey)
                    }
                    self.engineOK = true
                    self.ttsOK = t
                    self.noteModel(model)
                } else {
                    if base != self.server { self.deadUntil[base] = Date().addingTimeInterval(120) }
                    self.probeNext()
                }
            }
        }.resume()
    }

    /// 首行标语后面挂上电脑当前真实在跑的模型名，避免"以为还在 80B"这种糊涂账。
    private func noteModel(_ m: String) {
        guard !m.isEmpty, let i = msgs.firstIndex(where: { $0.role == .sys }) else { return }
        let line = "[ 手机直连 AgentShell · 原生界面 · " + m + " ]"
        if msgs[i].text != line { msgs[i].text = line }
    }

    // MARK: - 发消息（流式）

    /// 发一句话给电脑。返回 false = 这一句被挡下了（上一轮还没收尾），调用方要知道，
    /// 否则通话页会一直停在"思考中"等一个永远不会来的回答。
    @discardableResult
    func send(_ text: String, voice: Bool = false) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return false }
        input = ""
        busy = true
        // 【v3】先看用户这句话要不要放歌——手机自己决定，不等电脑给标记
        let intent = MusicIntent.parse(t)
        wantMusic = intent.wantMusic
        wantVocal = intent.vocal
        wantStopMusic = intent.stop
        wantSong = intent.song
        musicFired = false
        msgs.append(Msg(role: .user, text: t))
        let ai = Msg(role: .ai, text: "", streaming: true)
        let aiID = ai.id
        msgs.append(ai)

        guard let url = URL(string: server + "/chat") else {
            fail(aiID, "电脑地址不对，点右上角齿轮改地址")
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("", forHTTPHeaderField: "X-Token")

        // 历史里去掉刚加的这一句（它已经在 text 里），避免电脑端重复收到同一句
        var prior = msgs.filter { $0.role != .sys && $0.id != aiID }
        if !prior.isEmpty { prior.removeLast() }
        let hist: [[String: String]] = prior.suffix(24)
            .map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] }
        // voice=true：语音通话进来的句子。电脑端据此走"语音快通道"（短提示词、限长输出），
        // 否则会被 6856 字的期货提示词拖到 30~120 秒（35B 全 CPU，prefill 只有 31 tok/s）。
        let body: [String: Any] = ["text": t, "messages": hist, "voice": voice]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // v2.1 轮询模式：POST /chat 秒回任务号，再每 1.5 秒 GET /poll?id=N 取结果。
        // 之前的 SSE 长连接在蒲公英隧道上会悄悄断掉（电脑推数据才发现对面没了），
        // 改成与健康检查相同的短请求方式——这种在你手机上已被证明稳定。
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            guard let d = data, err == nil,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let id = (obj["id"] as? NSNumber)?.uint64Value, id > 0 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    self.fail(aiID, code == 429 ? "引擎正在处理上一轮，等几秒再发" : "电脑没有接受（HTTP \(code)）")
                }
                return
            }
            self.pollID = id
            DispatchQueue.main.async { self.startPolling(aiID) }
        }.resume()
        return true
    }

    private func startPolling(_ aiID: UUID) {
        pollTimer?.invalidate()
        pollFails = 0
        pollStartedAt = Date()          // 起等时间，用于"电脑端静默丢消息"的超时兜底
        musicFired = false
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollOnce(aiID)
        }
    }

    private func pollOnce(_ aiID: UUID) {
        guard let url = URL(string: "\(server)/poll?id=\(pollID)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            guard let d = data, err == nil,
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                self.pollFails += 1
                if self.pollFails >= 5 {
                    DispatchQueue.main.async {
                        self.pollTimer?.invalidate()
                        self.fail(aiID, "电脑连不上了，检查蒲公英")
                    }
                }
                return
            }
            self.pollFails = 0
            let done = (obj["done"] as? Bool) ?? false
            let text = (obj["text"] as? String) ?? ""
            DispatchQueue.main.async {
                guard let i = self.msgs.firstIndex(where: { $0.id == aiID }) else { return }
                // 【2026-11-18 超时兜底】电脑端在"上一轮还没收尾"的瞬间会把新消息静默丢掉
                // （gui.cpp: if (g_busy) return;），这条 id 永远不会 done，手机就卡在空泡里
                // 一直转。等满 150 秒还没有一个字，就明确报错并放开输入框，别让人对着空泡干等。
                if !done, self.msgs[i].text.isEmpty,
                   let t0 = self.pollStartedAt, Date().timeIntervalSince(t0) > 150 {
                    self.pollTimer?.invalidate()
                    self.fail(aiID, "电脑端没接住这条（上一轮还没收尾时会被丢），划掉 App 重开再发一次")
                    return
                }
                if !text.isEmpty {
                    // 电脑端老版本仍可能塞 [music:..] 标记：只负责把标记剥干净再显示，
                    // 播不播由用户这句话的意图决定（fireMusic），不再等电脑给钥匙。
                    var t = text
                    if let tag = MusicVM.parseMusicTag(t) { t = tag.cleaned }
                    if Self.looksLikeToolCall(t) { t = Self.toolCallHint }
                    self.msgs[i].text = t
                    self.fireMusic(replyText: t)
                }
                if done {
                    self.pollTimer?.invalidate()
                    self.msgs[i].streaming = false
                    // 兜底：万一文本帧没到（done 单独到），这里再试一次
                    var finalText = self.msgs[i].text
                    if let tag = MusicVM.parseMusicTag(finalText) {
                        finalText = tag.cleaned
                        self.msgs[i].text = finalText
                    }
                    if Self.looksLikeToolCall(self.msgs[i].text) {
                        self.msgs[i].text = Self.toolCallHint      // 别把 JSON 当回答留在屏幕上
                    }
                    self.fireMusic(replyText: self.msgs[i].text)
                    if self.msgs[i].text.isEmpty { self.msgs[i].text = "[ 电脑没有返回内容 ]" }
                    // 放歌时不朗读——朗读会抢占音频会话，把歌打断
                    else if self.autoRead && !self.musicFired { self.speak(self.msgs[i].text) }
                    self.busy = false
                    self.onReplyDone?(self.msgs[i].text)
                }
            }
        }.resume()
    }

    /// 【v3】一轮里只处理一次音乐：要停就停，要放就让手机自己从曲库点一首。
    /// 完全不依赖电脑端塞标记——旧方案任何一环掉链子就"标记原样显示 + 没有声音"。
    private func fireMusic(replyText: String = "") {
        guard !musicFired else { return }
        if wantStopMusic {
            musicFired = true
            MusicVM.shared.stop()
        } else if wantMusic {
            musicFired = true
            MusicVM.shared.playLibrary(vocalOnly: wantVocal, hint: replyText, songHint: wantSong)
        }
    }

    private func fail(_ id: UUID, _ err: String) {
        pollTimer?.invalidate()
        if let i = msgs.firstIndex(where: { $0.id == id }) {
            msgs[i].streaming = false
            if msgs[i].text.isEmpty {
                msgs[i].text = "[ 连接失败：\(err) ]"
            } else {
                msgs[i].text += "\n[ 中断：\(err) ]"
            }
        }
        busy = false
        sse = nil
        onReplyDone?("")
    }

    func stopSpeaking() {
        player?.stop()
        player = nil
    }

    // MARK: - 朗读（电脑合成，手机播放）

    func speak(_ text: String) {
        guard let url = URL(string: server + "/tts") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let data = data, err == nil,
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback)
                    try AVAudioSession.sharedInstance().setActive(true)
                    self.player = try AVAudioPlayer(data: data)
                    self.player?.play()
                } catch { }
            }
        }.resume()
    }
}

// MARK: - 音乐意图

/// 【v3】从用户这句话判断要不要放歌、放哪一类、还是让停。
/// 手机端据此自己点歌，不再依赖电脑端在回复里塞 [music:key=..] 标记。
/// 【v4】再抽一句"点名的歌/歌手"：曲库有就精准播，没有就跳酷狗搜。
struct MusicIntent {
    var wantMusic = false
    var vocal = false
    var stop = false
    /// 用户点名的歌名/歌手（"放安和桥" → 安和桥）。泛泛的"放音乐""来点人声"为 nil。
    var song: String? = nil

    /// 只有这些词的不算点名（否则"放点音乐"会被当成歌名去搜）
    private static let generic = [
        "音乐", "歌曲", "歌", "人声", "纯音乐", "伴奏", "背景音乐", "轻音乐", "纯音",
        "随便", "好听", "老歌", "新歌", "慢歌", "快歌", "dj", "电音", "摇滚", "流行",
        "中文", "英文", "粤语", "日文", "韩文", "外文", "安静", "舒缓", "伤感", "欢快",
        "睡前", "工作", "学习", "开车", "儿歌", "经典", "怀旧", "什么都行", "什么都好"
    ]

    private static let verbs = [
        "播放一下", "播放", "放一首", "放首", "放一下", "放一个", "放点", "放个", "放",
        "来一首", "来首", "来一个", "来点", "我想听", "想听", "听听", "听一下", "听",
        "点一首", "点首", "点个", "唱一首", "唱首", "唱", "整一首", "整首"
    ]

    /// 从整句里剥出歌名：去掉动词、量词、句尾的"的歌/吧/呗"和标点
    private static func extractSong(_ s: String) -> String? {
        var hit: (String.Index, String)? = nil
        for v in verbs {
            if let r = s.range(of: v) {
                if hit == nil || r.lowerBound < hit!.0 { hit = (r.lowerBound, v) }
            }
        }
        guard let (idx, verb) = hit else { return nil }
        var rest = String(s[idx...]).dropFirst(verb.count)
        // 去掉残余的"一下/一点/一首"等量词
        for p in ["一下", "一点", "一些", "一首", "一首歌", "首", "个", "点儿", "点"] {
            if rest.hasPrefix(p) { rest = rest.dropFirst(p.count) }
        }
        var t = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉句尾语气/后缀
        for suf in ["的歌吧", "的歌好听吗", "的歌", "歌曲", "音乐", "吧", "呗", "好吗",
                    "好不好", "可以吗", "行吗", "谢谢", "听听"] {
            if t.hasSuffix(suf) { t = String(t.dropLast(suf.count)) }
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " 《》\"'“”‘’，。！!？?、~～…"))
        guard t.count >= 1, t.count <= 30 else { return nil }
        let low = t.lowercased()
        // 整句就是一个泛词 → 不算点名
        if generic.contains(where: { low == $0 || low == $0.lowercased() }) { return nil }
        // 只剩虚词、或者明显是请求句式 → 不算点名
        let junk = ["音乐", "歌曲", "首歌", "一些", "什么", "怎么", "能不能", "可以", "一个", "点", "些"]
        if junk.contains(where: { low == $0 }) { return nil }
        if low.contains("音乐") || low.contains("歌曲") { return nil }
        return t
    }

    static func parse(_ s: String) -> MusicIntent {
        var i = MusicIntent()
        let stopKeys = ["停止播放", "别放了", "不要放了", "别放", "不要放", "关掉音乐",
                        "关音乐", "停止音乐", "别唱了", "停下音乐", "关了吧"]
        if stopKeys.contains(where: { s.contains($0) }) {
            i.stop = true
            return i
        }
        let vocalKeys = ["人声", "唱歌", "唱的", "有词", "vocal", "歌曲", "流行"]
        let musicKeys = ["播放", "放一首", "放首", "放点", "放个", "放歌", "放音乐",
                         "来一首", "来点", "来首", "听听", "想听", "听歌", "整一首", "点歌"]
        if musicKeys.contains(where: { s.contains($0) }) || vocalKeys.contains(where: { s.contains($0) }) {
            i.wantMusic = true
        }
        if vocalKeys.contains(where: { s.contains($0) }) { i.vocal = true }
        // 单字"放"/"听"/"唱"+具体名字 也算点歌（"放安和桥"）
        i.song = extractSong(s)
        if i.song != nil { i.wantMusic = true }
        return i
    }
}
