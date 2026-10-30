import SwiftUI
import WebKit
import AVFoundation
import Speech
import UIKit

// 电脑端服务地址候选（蒲公英组网 IP 变了不用重编壳：启动后自动探测，谁通用谁）
private let SERVER_CANDIDATES = [
    "http://172.16.2.103:8000",  // 本机（至强）蒲公英地址 · GGUF 8000（172.16.2.248 有线网卡已断，2026-10-30 换为 VPN 卡地址）
    "http://192.168.1.8:8000",   // 手机与电脑同一 WiFi 时直连
]
private var SERVER = SERVER_CANDIDATES[0]

/// 探测某个地址的 /health，回调保证在主线程
private func probeHealth(_ base: String, timeout: TimeInterval = 3,
                         completion: @escaping (Bool) -> Void) {
    guard let url = URL(string: base + "/health") else {
        DispatchQueue.main.async { completion(false) }
        return
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    req.cachePolicy = .reloadIgnoringLocalCacheData
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        DispatchQueue.main.async { completion(code == 200 && data != nil) }
    }.resume()
}

/// 按顺序探测候选地址，命中即更新全局 SERVER
private func resolveServer(index: Int = 0, completion: (() -> Void)? = nil) {
    if index >= SERVER_CANDIDATES.count { completion?(); return }
    let base = SERVER_CANDIDATES[index]
    probeHealth(base) { ok in
        if ok {
            SERVER = base
            completion?()
        } else {
            resolveServer(index: index + 1, completion: completion)
        }
    }
}

// ---------------- JSON / JS 字符串工具 ----------------
private func jsonString(_ obj: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

/// 生成合法的 JS 字符串字面量（自动处理引号、换行、中文）
private func jsLiteral(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
    let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(arr.dropFirst().dropLast())
}

// ---------------- 原生桥：接口请求 + 本地语音识别 + 朗读 ----------------
final class NativeBridge: NSObject, WKScriptMessageHandler,
                          AVAudioPlayerDelegate {

    weak var webView: WKWebView?

    // ---- iOS 本机语音识别（SFSpeech，音频不出手机）----
    private var audioEngine: AVAudioEngine?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechGranted = false
    private var speechFinished = false

    private var player: AVAudioPlayer?
    private var ttsLoading = false

    // ========== 消息入口：api（接口） / voice（按住说话） ==========
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "voice" {
            guard let cmd = message.body as? String else { return }
            switch cmd {
            case "down":   startRecording()
            case "up":     stopRecording(cancel: false)
            case "cancel": stopRecording(cancel: true)
            default: break
            }
            return
        }

        guard message.name == "api",
              let body = message.body as? [String: Any] else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        let method = body["method"] as? String ?? ""
        let params = body["params"] as? [String: Any] ?? [:]

        switch method {
        case "health":
            health(id)
        case "reset":
            reset(id)
        case "history":
            // 共享历史：桌面端和手机端同一份，?since=<id> 只取新增
            history(id,
                    since: (params["since"] as? NSNumber)?.intValue ?? 0,
                    limit: (params["limit"] as? NSNumber)?.intValue ?? 60)
        case "chat":
            chat(id, params)
        case "tts":
            speak(id, text: params["text"] as? String ?? "")
        case "ttsStop":
            stopPlayback()
            resolve(id, ["playing": false])
        case "alerts":
            // 取盯盘提醒：界面上每 10 秒拉一次，有新的就弹窗 + 震一下
            alerts(id, since: (params["since"] as? NSNumber)?.intValue ?? 0)
        case "buzz":
            // iOS 的 WKWebView 不支持 navigator.vibrate，震动只能走原生
            buzz(id, style: params["style"] as? String ?? "medium")
        default:
            reject(id, "未知方法：\(method)")
        }
    }

    // ========== 回调网页 ==========
    private func eval(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func resolve(_ id: Int, _ data: [String: Any]) {
        eval("window.__shiyiCb && window.__shiyiCb(\(id), \(jsLiteral(jsonString(["ok": true, "data": data]))));")
    }

    private func reject(_ id: Int, _ message: String) {
        eval("window.__shiyiCb && window.__shiyiCb(\(id), \(jsLiteral(jsonString(["ok": false, "error": message]))));")
    }

    private func status(_ text: String, _ level: String = "") {
        eval("window.__shiyiStatus && window.__shiyiStatus(\(jsLiteral(text)), \(jsLiteral(level)));")
    }

    // ========== HTTP ==========
    private func post(_ path: String, json: [String: Any]?,
                      completion: @escaping (Data?, Int, String?) -> Void) {
        guard let url = URL(string: SERVER + path) else {
            completion(nil, 0, "地址错误"); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let json = json,
           let body = try? JSONSerialization.data(withJSONObject: json, options: []) {
            req.httpBody = body
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if err != nil { resolveServer() }   // 连不上就顺手换下一个可用地址
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { completion(data, code, err?.localizedDescription) }
        }.resume()
    }

    // ========== 健康检查 ==========
    private func health(_ id: Int) {
        // 当前地址不通就自动换候选，不用每次手点「检」
        probeHealth(SERVER) { [weak self] ok in
            guard let self = self else { return }
            if ok { self.healthRequest(id); return }
            resolveServer { self.healthRequest(id) }
        }
    }

    private func healthRequest(_ id: Int) {
        guard let url = URL(string: SERVER + "/health") else { reject(id, "地址错误"); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err { self.reject(id, "连不上电脑：\(err)"); return }
                guard let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.reject(id, "返回值异常"); return
                }
                self.resolve(id, ["status": obj["status"] as? String ?? "ok"])
            }
        }.resume()
    }

    // ========== 盯盘提醒 ==========
    /// GET 一个 JSON，回调 (对象, 状态码)。连不上给 (nil, 0)。
    private func fetchJSON(_ path: String, _ cb: @escaping ([String: Any]?, Int) -> Void) {
        guard let url = URL(string: SERVER + path) else { cb(nil, 0); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var obj: [String: Any]?
            if err == nil, let d = data {
                obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            DispatchQueue.main.async { cb(obj, code) }
        }.resume()
    }

    /// 拉取盯盘提醒。
    /// 正路是 /alerts；如果电脑端还是旧代码（404），就退回去读静态清单
    /// /manifest.json —— 那个文件每次请求都重新读盘，所以不重启服务也能送达。
    private func alerts(_ id: Int, since: Int) {
        func viaManifest() {
            fetchJSON("/manifest.json") {
                [weak self] obj, code in
                guard let self = self else { return }
                guard code == 200, let m = obj else { self.reject(id, "连不上电脑"); return }
                let al = (m["alerts"] as? [[String: Any]]) ?? []
                let items = al.filter { (($0["id"] as? NSNumber)?.intValue ?? 0) > since }
                let last = ((al.last?["id"]) as? NSNumber)?.intValue ?? 0
                self.resolve(id, ["payload": ["items": items, "last": last]])
            }
        }

        func live() {
            fetchJSON("/alerts?since=\(since)") { [weak self] obj, code in
                guard let self = self else { return }
                if code == 200, let o = obj { self.resolve(id, ["payload": o]); return }
                viaManifest()
            }
        }

        probeHealth(SERVER, timeout: 1.5) { ok in
            if ok { live(); return }
            resolveServer { live() }
        }
    }

    /// 震动。style: light / medium / heavy
    private func buzz(_ id: Int, style: String) {
        let g = UIImpactFeedbackGenerator(
            style: style == "heavy" ? .heavy : (style == "light" ? .light : .medium))
        g.prepare()
        g.impactOccurred()
        if style == "heavy" {
            // 紧急提醒多震两下，口袋里有感觉
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
        resolve(id, ["ok": true])
    }

    // ========== 清空会话 ==========
    private func reset(_ id: Int) {
        post("/api/reset", json: [:]) { [weak self] data, code, err in
            guard let self = self else { return }
            if let err = err { self.reject(id, "清空失败：\(err)"); return }
            if code >= 400 { self.reject(id, "清空失败（HTTP \(code)）"); return }
            self.resolve(id, ["ok": true])
        }
    }

    // ========== 共享历史 ==========
    /// 读服务端落盘的共享历史。走原生 GET（CFNetwork），
    /// 这样即使界面是从包里 file:// 加载的，也不会被 WKWebView 的跨源策略挡掉。
    private func history(_ id: Int, since: Int, limit: Int) {
        let qs = since > 0 ? "?since=\(since)&limit=\(limit)" : "?limit=\(limit)"
        fetchJSON("/history" + qs) { [weak self] obj, code in
            guard let self = self else { return }
            guard let obj = obj else {
                self.reject(id, "历史读取失败（HTTP \(code)）")
                return
            }
            self.resolve(id, obj)
        }
    }

    // ========== 对话 ==========
    private func chat(_ id: Int, _ params: [String: Any]) {
        let text = (params["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { reject(id, "内容为空"); return }
        let payload: [String: Any] = [
            "text": text,
            "session_id": params["session"] as? String ?? "",
            "to": params["to"] as? String ?? "shiyi"
        ]
        post("/chat", json: payload) { [weak self] data, code, err in
            guard let self = self else { return }
            if let err = err {
                self.reject(id, "请求失败：\(err)")
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.reject(id, "电脑返回异常（HTTP \(code)）")
                return
            }
            if let e = obj["error"] as? String, !e.isEmpty {
                self.reject(id, e)
                return
            }
            let reply = obj["reply"] as? String ?? ""
            self.resolve(id, ["reply": reply, "done": true])
        }
    }

    // ========== 朗读（原生播放，不经过网页音频） ==========
    private func speak(_ id: Int, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { reject(id, "内容为空"); return }
        if ttsLoading { reject(id, "正在合成中"); return }
        ttsLoading = true
        post("/tts", json: ["text": String(t.prefix(500))]) { [weak self] data, code, err in
            guard let self = self else { return }
            self.ttsLoading = false
            if let err = err { self.reject(id, "朗读失败：\(err)"); return }
            guard let data = data, !data.isEmpty, code < 400 else {
                self.reject(id, "朗读失败（HTTP \(code)）"); return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                               options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                self.player?.stop()
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.prepareToPlay()
                p.play()
                self.player = p
                self.resolve(id, ["playing": true])
            } catch {
                self.reject(id, "播放失败：\(error.localizedDescription)")
            }
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.player = nil
            self.eval("window.__shiyiTtsDone && window.__shiyiTtsDone();")
        }
    }

    // ========== 按住说话：iOS 本机 SFSpeech 识别（音频不出手机，豆包式） ==========
    private func startRecording() {
        if audioEngine != nil { return }
        stopPlayback()
        speechFinished = false
        let begin: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.startListening()
        }
        if speechGranted {
            DispatchQueue.main.async { begin() }
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            self.speechGranted = (status == .authorized)
            DispatchQueue.main.async {
                if !self.speechGranted {
                    self.status("语音识别权限被拒绝", "err")
                    self.rejectRecording("请在 设置→GGUF 里打开语音识别与麦克风权限")
                    return
                }
                begin()
            }
        }
    }

    private func denied() {
        status("麦克风权限被拒绝", "err")
        eval("window.__shiyiAsr && window.__shiyiAsr('', false, '请到 设置→GGUF 里打开麦克风');")
    }

    private func rejectRecording(_ message: String) {
        eval("window.__shiyiAsr && window.__shiyiAsr('', false, \(jsLiteral(message)));")
    }

    private func stopRecording(cancel: Bool) {
        if cancel {
            // 上移取消：静默停止，不弹"没听清"
            speechFinished = true
            stopEngine()
            return
        }
        guard let request = speechRequest else {
            stopEngine()
            rejectRecording("没有正在录制的语音")
            return
        }
        status("识别中…", "warn")
        speechFinished = false
        request.endAudio()
        // 松手后 8 秒内识别回调未触发则兜底返回
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, !self.speechFinished else { return }
            self.speechFinished = true
            self.stopEngine()
            self.rejectRecording("识别超时，再说一次")
        }
    }

    /// 启动本机识别（AVAudioEngine 采集 + SFSpeech 中文识别）
    private func startListening() {
        stopEngine()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                            mode: .default,
                                                            options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            status("音频初始化失败", "err")
            rejectRecording("音频初始化失败")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            status("本机识别不可用", "err")
            rejectRecording("本机语音识别不可用")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        speechRequest = request

        let engine = AVAudioEngine()
        let node = engine.inputNode
        var fmt = node.outputFormat(forBus: 0)
        // inputNode 格式异常（sampleRate==0）时直接 installTap 会崩溃：用会话采样率兜底
        if fmt.sampleRate == 0 || fmt.channelCount == 0 {
            let sr = AVAudioSession.sharedInstance().sampleRate > 0
                ? AVAudioSession.sharedInstance().sampleRate : 16000
            guard let f = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else {
                rejectRecording("音频格式异常")
                return
            }
            fmt = f
        }
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
                    if self.speechFinished { return }
                    if result?.isFinal == true || error != nil {
                        self.speechFinished = true
                        let text = result?.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        self.stopEngine()
                        if !text.isEmpty {
                            self.status("已识别", "ok")
                            self.eval("window.__shiyiAsr && window.__shiyiAsr(\(jsLiteral(text)), true, '');")
                        } else {
                            self.status("没听清", "warn")
                            self.rejectRecording("没听清，再说一次")
                        }
                    }
                }
            }
            status("正在听…", "warn")
        } catch {
            stopEngine()
            status("识别启动失败", "err")
            rejectRecording("识别启动失败")
        }
    }

    private func stopEngine() {
        if let t = speechTask { t.cancel(); speechTask = nil }
        speechRequest = nil
        if let e = audioEngine {
            e.stop()
            e.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }
    }
}

// ---------------- WebView 壳 ----------------
struct WebView: UIViewRepresentable {
    let bridge: NativeBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(bridge, name: "api")
        config.userContentController.add(bridge, name: "voice")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.96, green: 0.955, blue: 0.945, alpha: 1)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false

        bridge.webView = webView

        // 界面优先从电脑上的服务端拉（2026-10-23）：
        // 以前 index.html 打进包里，改一行界面就得重新打包安装，手机端永远落后一个包。
        // 但旧写法是直接拿 SERVER（候选第 0 个 = 已停用的联想机地址）去 load，
        // 地址一死必然超时、退回包内 file:// 页面，而 file:// 页面 fetch 服务端会被
        // WKWebView 跨源拦掉 —— 表现就是"界面能开、历史一条不显示、发消息也没回显"。
        // 现在：先并发探测候选地址，先通先加载；全都不通才退回包内页面（走原生桥，功能仍是全的）。
        webView.navigationDelegate = context.coordinator
        context.coordinator.begin(webView)

        // 长按不弹菜单，操作更像原生 App
        let css = "addEventListener('DOMContentLoaded',function(){var s=document.createElement('style');" +
                  "s.textContent='*{-webkit-touch-callout:none;}';document.head.appendChild(s);});"
        webView.evaluateJavaScript(css, completionHandler: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 先探测地址再决定加载哪份界面。
    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var view: WKWebView?
        private var decided = false
        private var isRemote = false

        func begin(_ webView: WKWebView) {
            view = webView
            let group = DispatchGroup()
            for base in SERVER_CANDIDATES {
                group.enter()
                probeHealth(base, timeout: 4) { ok in
                    if ok { self.pick(base) }
                    group.leave()
                }
            }
            // 全部候选都不通（电脑关机 / 不在同一网络）→ 退回包内页面
            group.notify(queue: .main) {
                if !self.decided {
                    self.decided = true
                    self.loadLocal()
                }
            }
        }

        private func pick(_ base: String) {
            guard !decided else { return }
            decided = true
            isRemote = true
            SERVER = base                      // 原生桥的接口也统一用这个地址
            guard let url = URL(string: base + "/") else { loadLocal(); return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.cachePolicy = .reloadIgnoringLocalCacheData
            view?.load(req)
        }

        private func loadLocal() {
            isRemote = false
            if let local = Bundle.main.url(forResource: "index", withExtension: "html") {
                view?.loadFileURL(local, allowingReadAccessTo: local.deletingLastPathComponent())
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            if isRemote { loadLocal() }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            if isRemote { loadLocal() }
        }
    }
}

// ---------------- 入口 ----------------
@main
struct GGUFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var holder = BridgeHolder()

    var body: some View {
        WebView(bridge: holder.bridge)
            .ignoresSafeArea()
            .preferredColorScheme(.light)
    }
}

final class BridgeHolder: ObservableObject {
    let bridge = NativeBridge()
}
