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
    @Published private(set) var server: String

    private var sse: SSEClient?
    private var timer: Timer?
    private var pollTimer: Timer?
    private var pollID: UInt64 = 0
    private var pollFails = 0
    private var player: AVAudioPlayer?

    static let defaultServer = "http://172.16.2.103:8099"
    private static let serverKey = "wuj_server_v2"

    init() {
        let s = UserDefaults.standard.string(forKey: ChatVM.serverKey) ?? ""
        server = s.isEmpty ? ChatVM.defaultServer : s
    }

    deinit { timer?.invalidate(); pollTimer?.invalidate() }

    // MARK: - 服务地址

    func saveServer(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var v = t
        if !v.hasPrefix("http://") && !v.hasPrefix("https://") { v = "http://" + v }
        server = v
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
        guard let url = URL(string: server + "/health") else {
            engineOK = false; ttsOK = false; return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            var e = false, t = false
            if let d = data, err == nil,
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                let eng = obj["engine"] as? String ?? ""
                e = (eng == "online" || eng == "standby")
                t = (obj["tts"] as? Bool) ?? false
            }
            DispatchQueue.main.async {
                self?.engineOK = e
                self?.ttsOK = t
            }
        }.resume()
    }

    // MARK: - 发消息（流式）

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        input = ""
        busy = true
        msgs.append(Msg(role: .user, text: t))
        let ai = Msg(role: .ai, text: "", streaming: true)
        let aiID = ai.id
        msgs.append(ai)

        guard let url = URL(string: server + "/chat") else {
            fail(aiID, "电脑地址不对，点右上角齿轮改地址")
            return
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
        let body: [String: Any] = ["text": t, "messages": hist]
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
    }

    private func startPolling(_ aiID: UUID) {
        pollTimer?.invalidate()
        pollFails = 0
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
                if !text.isEmpty { self.msgs[i].text = text }
                if done {
                    self.pollTimer?.invalidate()
                    self.msgs[i].streaming = false
                    if self.msgs[i].text.isEmpty { self.msgs[i].text = "[ 电脑没有返回内容 ]" }
                    else if self.autoRead { self.speak(self.msgs[i].text) }
                    self.busy = false
                }
            }
        }.resume()
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
