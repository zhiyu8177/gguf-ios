import SwiftUI
import WebKit
import AVFoundation
import Speech

/// GGUF 工作台手机壳：电脑的蒲公英虚拟 IP（172.16.2.248）· GGUF 8000 端口
/// 换 IP 只改这一处 + ios/index.html 里的 DEFAULT_SERVER
let SERVER = "http://172.16.2.248:8000"

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
/// 导致启动后 JS 调原生桥（health）时野指针闪退（拾壹同款模式）
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
        bridge.webView = wv
        // iOS 16.0.x 的 WKWebView：loadFileURL 崩溃、baseURL 传 http 地址也崩溃，
        // 只能用 loadHTMLString + baseURL nil（已实测不闪退）。
        // about: 下 localStorage 不可用由 index.html 的 try/catch 兜底（默认地址直连）。
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
class Coordinator: NSObject, WKScriptMessageHandler {
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
        case "tts":      tts(text: body["text"] as? String ?? "", id: id)
        case "ttsStop":  player?.stop(); reply(id, true, "{}")
        case "health":   health(id: id)
        case "recStart": recStart(id: id)
        case "recStop":  recStop(id: id)
        default:         reply(id, false, "{\"error\":\"unknown action\"}")
        }
    }

    // MARK: - 回调
    func reply(_ id: String, _ ok: Bool, _ payload: String) {
        let js = "window.WJ&&window.WJ._cb(\(q(id)),\(ok ? "true" : "false"),\(q(payload)))"
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js, completionHandler: nil) }
    }
    func q(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s),
              let out = String(data: d, encoding: .utf8) else { return "\"\"" }
        return out
    }

    // MARK: - TTS：电脑合成 → 原生播放（可精确停止）
    func tts(text: String, id: String) {
        guard !text.isEmpty else { return reply(id, false, "{\"error\":\"empty\"}") }
        var req = URLRequest(url: URL(string: SERVER + "/tts")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        req.timeoutInterval = 180
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard let data = data, err == nil else {
                return self.reply(id, false, "{\"error\":\"tts request failed\"}")
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

    // MARK: - 健康检查
    func health(id: String) {
        URLSession.shared.dataTask(with: URL(string: SERVER + "/health")!) { data, _, err in
            if let data = data, err == nil, let s = String(data: data, encoding: .utf8) {
                self.reply(id, true, self.q(s))
            } else {
                self.reply(id, false, "{\"engine\":false,\"tts\":false}")
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
