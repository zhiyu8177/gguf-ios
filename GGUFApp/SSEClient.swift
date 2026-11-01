import Foundation

/// 原生 SSE 流式客户端（iOS 14 可用，不依赖 async/await、不依赖 WKWebView）
/// 服务端 /chat 返回：data:{"delta":"..."}\n\n
final class SSEClient: NSObject, URLSessionDataDelegate {

    var onDelta: ((String) -> Void)?
    var onDone: (() -> Void)?
    var onError: ((String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var textBuf = ""          // 已解码的文本缓冲（按 \n\n 切帧）
    private var dataBuf = Data()      // 未解码干净的字节（UTF-8 多字节可能被切断）
    private var finished = false
    private var statusOK = true

    func start(_ req: URLRequest) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        task = s.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        finished = true
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let h = response as? HTTPURLResponse, h.statusCode != 200 {
            statusOK = false
            let code = h.statusCode
            DispatchQueue.main.async {
                self.onError?(code == 429 ? "引擎正在处理上一轮，等几秒再发" : "HTTP \(code)")
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataBuf.append(data)
        guard let str = String(data: dataBuf, encoding: .utf8) else {
            // 半截中文字符，等下一块再拼；超过 64KB 说明真乱了，丢弃重置
            if dataBuf.count > 65536 { dataBuf = Data() }
            return
        }
        dataBuf = Data()
        textBuf += str
        var frames = textBuf.components(separatedBy: "\n\n")
        textBuf = frames.removeLast()
        for f in frames { parse(frame: f) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        session.finishTasksAndInvalidate()
        self.session = nil
        if let e = error, statusOK {
            let msg = (e as NSError).code == NSURLErrorCancelled ? "已取消" : e.localizedDescription
            DispatchQueue.main.async { self.onError?(msg) }
            return
        }
        if statusOK { DispatchQueue.main.async { self.onDone?() } }
    }

    private func parse(frame: String) {
        for line in frame.components(separatedBy: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw == "[DONE]" { continue }
            guard let d = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                DispatchQueue.main.async { self.onDelta?(delta) }
            }
        }
    }
}
