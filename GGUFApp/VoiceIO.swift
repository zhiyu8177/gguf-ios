import Foundation
import Combine
import AVFoundation
import Speech

/// 语音输入 v2.3：默认录音上传电脑 FunASR（paraformer，准），失败自动降级 Apple 本机识别。
/// 音频只在局域网里走（手机 → 电脑 8099 → 电脑本机 8123），不出外网。
/// 用法：start() 开始录音 → stop() 结束 → onText 回调识别结果
final class VoiceIO: ObservableObject {

    var onText: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onError: ((String) -> Void)?

    /// true = 录音上传电脑转写（v2.3 默认）；电脑没接上会自动降级本机识别
    var serverASR = true
    /// 电脑地址（http://172.16.2.103:8099），setup 时由 ChatView/CallVM 填
    var serverURL: String?

    /// 免提通话模式：单次聆听最长秒数（到时把结果当最终结果），nil = 不限制
    var maxListenSeconds: Double?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var speechGranted = false
    private var lastPartial = ""
    private var active = false
    private var tapInstalled = false
    private var timeoutItem: DispatchWorkItem?
    private var maxListenItem: DispatchWorkItem?

    // 服务器模式：AVAudioRecorder 直接出 16k 单声道 WAV
    private var recorder: AVAudioRecorder?
    private var recURL: URL?

    /// 请求权限（麦克风 + 语音识别），首次调用会弹系统授权框
    func requestAuth(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            self.speechGranted = (st == .authorized)
            AVAudioSession.sharedInstance().requestRecordPermission { micOK in
                DispatchQueue.main.async { done(micOK) }
            }
        }
    }

    func start() {
        teardown()
        lastPartial = ""
        active = true

        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setPreferredSampleRate(16000)
            try s.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            active = false
            onError?("麦克风被占用，稍后再试")
            return
        }

        // v2.3：录音上传模式——AVAudioRecorder 直出 16k 单声道 WAV，没有实时半截字
        if serverASR {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("asr_\(Int(Date().timeIntervalSince1970 * 1000)).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            guard let r = try? AVAudioRecorder(contentsOf: url, settings: settings) else {
                active = false
                onError?("录音启动失败")
                return
            }
            r.record()
            recorder = r
            recURL = url
            // 免提模式防呆：一直不说也有上限，超时自动按"结束"处理
            if let cap = maxListenSeconds {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, self.active else { return }
                    self.finishUpload()
                }
                maxListenItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + cap, execute: item)
            }
            return
        }

        // 原路径：Apple 本机识别（兜底模式）
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), rec.isAvailable else {
            active = false
            onError?("语音识别不可用（检查网络或系统设置）")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let eng = AVAudioEngine()
        let node = eng.inputNode
        var fmt = node.outputFormat(forBus: 0)
        if fmt.sampleRate == 0 || fmt.channelCount == 0 {
            let sr = AVAudioSession.sharedInstance().sampleRate > 0
                ? AVAudioSession.sharedInstance().sampleRate : 16000
            if let f = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) {
                fmt = f
            } else {
                active = false
                onError?("麦克风初始化失败")
                return
            }
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
            req.append(buffer)
        }
        tapInstalled = true
        eng.prepare()
        do {
            try eng.start()
        } catch {
            active = false
            onError?("录音启动失败")
            teardown()
            return
        }
        engine = eng

        // 免提模式：用户一直不停说也有上限，超时把已识别的半截当结果发出去
        if let cap = maxListenSeconds {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.active else { return }
                self.finish(text: self.lastPartial, error: nil)
            }
            maxListenItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + cap, execute: item)
        }

        task = rec.recognitionTask(with: req) { [weak self] result, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let r = result {
                    let t = r.bestTranscription.formattedString
                    if !t.isEmpty {
                        self.lastPartial = t
                        self.onPartial?(t)
                    }
                    if r.isFinal {
                        self.finish(text: t, error: nil)
                    }
                } else if err != nil {
                    self.finish(text: self.lastPartial, error: err)
                }
            }
        }
    }

    /// 松手：停止收音。服务器模式上传转写，本机模式等识别回调
    func stop() {
        guard active else { return }
        if serverASR {
            maxListenItem?.cancel(); maxListenItem = nil
            finishUpload()
            return
        }
        request?.endAudio()
        stopEngine()
        // 兜底：5 秒还没最终结果，就把已有的半截结果当结果用
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.active else { return }
            self.finish(text: self.lastPartial, error: nil)
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// 免提/挂断用：静默停止，结果作废、不触发任何回调
    func abort() {
        active = false
        timeoutItem?.cancel()
        timeoutItem = nil
        maxListenItem?.cancel()
        maxListenItem = nil
        lastPartial = ""
        if let r = recorder { r.stop(); r.deleteRecording() }
        recorder = nil
        recURL = nil
        teardown()
    }

    // MARK: - 服务器转写

    private func finishUpload() {
        guard active else { return }
        active = false
        maxListenItem?.cancel(); maxListenItem = nil
        recorder?.stop()
        let file = recURL
        recorder = nil
        recURL = nil
        upload(file)
    }

    private func upload(_ file: URL?) {
        guard let file = file else { onError?("录音文件丢失"); return }
        guard let base = serverURL else {
            fallbackFileASR(file, why: "没有电脑地址")
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            fallbackFileASR(file, why: "录音读取失败")
            return
        }
        guard let url = URL(string: base + "/asr") else {
            fallbackFileASR(file, why: "电脑地址不对")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { [weak self] d, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if err == nil, let d = d,
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    let t = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !t.isEmpty {
                        self.cleanup(file)
                        self.onText?(t)
                    } else {
                        // 电脑转出空：多半是没听清，按本机兜底再认一遍
                        self.fallbackFileASR(file, why: "电脑没听清")
                    }
                } else {
                    // 电脑没接上 /asr（老版本 AgentShell 或断线）：本机兜底
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    self.fallbackFileASR(file, why: "电脑转写不可用(\(code))")
                }
            }
        }.resume()
    }

    /// 兜底：Apple 对录音文件做识别（SFSpeechFileRecognitionRequest），音频不出手机
    private func fallbackFileASR(_ file: URL, why: String) {
        guard speechGranted else {
            cleanup(file)
            onError?("电脑转写不可用(\(why))，且没有语音识别权限")
            return
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), rec.isAvailable else {
            cleanup(file)
            onError?("电脑转写不可用(\(why))，本机识别也不可用")
            return
        }
        let req = SFSpeechFileRecognitionRequest(url: file)
        req.shouldReportPartialResults = false
        var finished = false
        let myTask = rec.recognitionTask(with: req) { [weak self] result, err in
            DispatchQueue.main.async {
                guard !finished else { return }
                if let r = result, r.isFinal {
                    finished = true
                    self?.deliver(file, r.bestTranscription.formattedString)
                } else if err != nil {
                    finished = true
                    self?.deliver(file, "")
                }
            }
        }
        task = myTask
        // 5 秒还没结果就放弃
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard !finished else { return }
            finished = true
            myTask.cancel()
            self.deliver(file, "")
        }
    }

    private func deliver(_ file: URL, _ t: String) {
        cleanup(file)
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { onError?("没听清，再说一次") } else { onText?(s) }
    }

    private func cleanup(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    private func finish(text: String, error: Error?) {
        guard active else { return }
        active = false
        timeoutItem?.cancel()
        timeoutItem = nil
        maxListenItem?.cancel()
        maxListenItem = nil
        teardown()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            onText?(t)
        } else {
            onError?("没听清，再说一次")
        }
    }

    private func stopEngine() {
        if let e = engine, e.isRunning { e.stop() }
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = nil
    }

    private func teardown() {
        stopEngine()
        task?.cancel()
        task = nil
        request = nil
    }
}
