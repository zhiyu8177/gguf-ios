import SwiftUI
import WebKit
import AVFoundation
import Speech

/// AgentShell 期货工作台手机壳（v1.2 重写版）
/// 默认连电脑蒲公英虚拟 IP 的 AgentShell 手机服务（8099）。
/// 地址存在 UserDefaults（键 wuj_server），App 内可改、重启保留；
/// WKUIDelegate 已实现，JS 的 window.prompt 可正常弹出输入框。
let DEFAULT_SERVER = "http://172.16.2.103:8099"
let SERVER_KEY = "wuj_server"

@main
struct GGUFApp: App {
    var body: some Scene {
        WindowGroup { ContentView().edgesIgnoringSafeArea(.all) }
    }
}

struct ContentView: View {
    @StateObject private var holder = BridgeHolder()
    var body: some View {
        WebViewContainer(bridge: holder.bridge).edgesIgnoringSafeArea(.all)
    }
}

/// 用 @StateObject 强持有原生桥，避免 SwiftUI 提前释放 Coordinator
func currentServer() -> String {
    let s = UserDefaults.standard.string(forKey: SERVER_KEY) ?? ""
    return s.isEmpty ? DEFAULT_SERVER : s
}

final class BridgeHolder: ObservableObject {
    let bridge = Coordinator()
}

struct WebViewContainer: UIViewRepresentable {
    let bridge: Coordinator
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(bridge, name: "api")
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.scrollView.bounces = false
        wv.uiDelegate = bridge          // 关键：没有这个 window.prompt 弹不出来
        bridge.webView = wv
        // iOS 16.0.x 的 WKWebView：loadFileURL 崩溃、baseURL 传 http 地址也崩溃，
        // 只能用 loadHTMLString + baseURL nil（已实测不闪退）。
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            wv.loadHTMLString(html, baseURL: nil)
        }
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { bridge }
}

/// 原生桥：JS 调 window.webkit.messageHandlers.api.postMessage({action,id,...})
/// 原生回调 window.WJ._cb(id, ok, payloadJsonString)
class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
    weak var webView: WKWebView?
    var player: AVAudioPlayer?

    // ---- 语音输入（豆包式：按住说话，iOS 本地 SFSpeech 识别，不依赖电脑端）----
    var audioEngine: AVAudioEngine?
    var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    var speechTask: SFSpeechRecognitionTask?
    var pendingID: String = ""
    var speechGranted = false
    var finishedReply = false

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let id = body["id"] as? String else { return }
        switch action {
        case "tts":      tts(text: body["text"] as? String ?? "", server: body["server"] as? String, id: id)
        case "ttsStop":  player?.stop(); reply(id, true, "{}")
        case "health":   health(id: id, server: body["server"] as? String)
        case "getServer": reply(id, true, "{\"server\":\(q(currentServer()))}")
        case "setServer":
            let s = (body["server"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, s.hasPrefix("http://") || s.hasPrefix("https://") {
                UserDefaults.standard.set(s, forKey: SERVER_KEY)
                reply(id, true, "{\"server\":\(q(s))}")
            } else {
                reply(id, false, "{\"error\":\"bad server\"}")
            }
        case "recStart": recStart(id: id)
        case "recStop":  recStop(id: id)
        default:         reply(id, false, "{\"error\":\"unknown action\"}")
        }
    }

    // MARK: - WKUIDelegate：让 window.prompt / alert / confirm 正常工作
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let root = rootVC() else { completionHandler(defaultText); return }
        let alert = UIAlertController(title: prompt, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        root.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let root = rootVC() else { completionHandler(); return }
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        root.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let root = rootVC() else { completionHandler(false); return }
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        root.present(alert, animated: true)
    }
    private func rootVC() -> UIViewController? {
        // keyWindow 是 iOS 15+ API，部署目标 14.0 必须带 #available 兜底
        var key: UIWindow? = nil
        if #available(iOS 15.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let ws = scene as? UIWindowScene, let k = ws.keyWindow { key = k; break }
            }
        }
        if key == nil {
            for w in UIApplication.shared.windows where w.isKeyWindow { key = w; break }
        }
        guard let k = key else { return nil }
        var vc = k.rootViewController
        while vc?.presentedViewController != nil { vc = vc?.presentedViewController }
        return vc
    }

    // MARK: - 回调
    func reply(_ id: String, _ ok: Bool, _ payload: String) {
        let js = "window.WJ&&window.WJ._cb(\(q(id)),\(ok ? "true" : "false"),\(q(payload)))"
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js, completionHandler: nil) }
    }
    func q(_ s: String) -> String {
        // JSONSerialization 顶层只接受数组/字典，裸传 String 会失败——必须包一层数组再掐头去尾
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let arr = String(data: d, encoding: .utf8), arr.count >= 2 else { return "\"\"" }
        return String(arr.dropFirst().dropLast())
    }

    // MARK: - TTS：电脑合成 → 原生播放（可精确停止）。AgentShell 暂无 /tts，会走失败分支
    func tts(text: String, server: String?, id: String) {
        guard !text.isEmpty else { return reply(id, false, "{\"error\":\"empty\"}") }
        let base = (server?.isEmpty == false ? server! : currentServer())
        guard let url = URL(string: base + "/tts") else {
            return reply(id, false, "{\"error\":\"bad address\"}")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        req.timeoutInterval = 60
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data = data, err == nil,
                  (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return self.reply(id, false, "{\"error\":\"tts unavailable\"}")
            }
            DispatchQueue.main.async {
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback)
                    try AVAudioSession.sharedInstance().setActive(true)
                    self.player = try AVAudioPlayer(data: data)
                    self.player?.play()
                    self.reply(id, true, "{\"playing\":true}")
                } catch {
                    self.reply(id, false, "{\"error\":\"player failed\"}")
                }
            }
        }.resume()
    }

    // MARK: - 健康检查（带 JS 传来的地址，失败回 ok=false 让 JS 引导改地址）
    func health(id: String, server: String?) {
        let base = (server?.isEmpty == false ? server! : currentServer())
        guard let url = URL(string: base + "/health") else {
            return reply(id, false, "{\"engine\":\"offline\",\"tts\":false}")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let data = data, err == nil,
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let s = String(data: data, encoding: .utf8) {
                self.reply(id, true, self.q(s))
            } else {
                self.reply(id, false, "{\"engine\":\"offline\",\"tts\":false}")
            }
        }.resume()
    }

    // MARK: - 语音识别（按住说话，松手出结果）
    func recStart(id: String) {
        pendingID = id
        finishedReply = false
        if speechGranted {
            DispatchQueue.main.async { self.startListening() }
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            self.speechGranted = (status == .authorized)
            DispatchQueue.main.async {
                guard self.speechGranted else {
                    self.reply(self.pendingID, false, "{\"error\":\"no speech permission\"}")
                    return
                }
                self.startListening()
            }
        }
    }

    func startListening() {
        stopEngine()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                            mode: .default,
                                                            options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            reply(pendingID, false, "{\"error\":\"audio session\"}")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            reply(pendingID, false, "{\"error\":\"recognizer unavailable\"}")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        speechRequest = request

        let engine = AVAudioEngine()
        let node = engine.inputNode
        var tapFormat = node.outputFormat(forBus: 0)
        // inputNode 格式异常（sampleRate==0）时直接 installTap 会崩溃：用会话采样率兜底
        if tapFormat.sampleRate == 0 || tapFormat.channelCount == 0 {
            let sr = AVAudioSession.sharedInstance().sampleRate > 0
                ? AVAudioSession.sharedInstance().sampleRate : 16000
            guard let f = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else {
                reply(pendingID, false, "{\"error\":\"bad format\"}")
                return
            }
            tapFormat = f
        }
        let fmt = tapFormat
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if self.finishedReply { return }
                    if result?.isFinal == true || error != nil {
                        self.finishedReply = true
                        let text = result?.bestTranscription.formattedString ?? ""
                        self.stopEngine()
                        let ok = error == nil && !text.isEmpty
                        self.reply(self.pendingID, ok, "{\"text\":\(self.q(text))}")
                    }
                }
            }
            reply(pendingID, true, "{\"recording\":true}")
        } catch {
            stopEngine()
            reply(pendingID, false, "{\"error\":\"engine start failed\"}")
        }
    }

    func recStop(id: String) {
        pendingID = id
        guard speechRequest != nil else {
            stopEngine()
            reply(id, false, "{\"error\":\"not recording\"}")
            return
        }
        speechRequest?.endAudio()
        // 若 6 秒内识别回调未触发（异常），兜底返回失败
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, !self.finishedReply else { return }
            self.finishedReply = true
            self.stopEngine()
            self.reply(self.pendingID, false, "{\"error\":\"recognize timeout\"}")
        }
    }

    func stopEngine() {
        if let t = speechTask { t.cancel(); speechTask = nil }
        speechRequest = nil
        if let e = audioEngine {
            e.stop()
            e.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }
    }
}
