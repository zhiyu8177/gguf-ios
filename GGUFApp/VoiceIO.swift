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
    // 免提模式静音断句（VAD）：用录音电平检测“说完一句”，静音 1.2 秒立刻上传
    private var meterTimer: Timer?
    private var speechSeen = false
    private var quietTicks = 0

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
            guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
                active = false
                onError?("录音启动失败")
                return
            }
            r.isMeteringEnabled = true
            r.record()
            recorder = r
            recURL = url
            // 免提模式：电平 VAD 断句（说完静音 1.2s 立刻发）+ 15s 兜底上限
            if maxListenSeconds != nil {
                startVAD()
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, self.active else { return }
                    self.finishUpload()
                }
                maxListenItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + maxListenSeconds!, execute: item)
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

    /// 免提通话断句：录音电平 > -38dB 视为在说话；说完连续静音 1.2 秒自动结束上传。
    /// （只有免提模式启用；按住说话不受影响，仍以松手为准）
    private func startVAD() {
        speechSeen = false
        quietTicks = 0
        meterTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.active, let r = self.recorder else { return }
            r.updateMeters()
            let db = r.averagePower(forChannel: 0)
            if db > -38 {
                self.speechSeen = true
                self.quietTicks = 0
            } else if self.speechSeen {
                self.quietTicks += 1
                if self.quietTicks >= 12 {
                    self.meterTimer?.invalidate()
                    self.meterTimer = nil
                    self.finishUpload()
                }
            }
        }
        meterTimer = t
    }

    private func stopVAD() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// 松手：停止收音。服务器模式上传转写，本机模式等识别回调
    func stop() {
        guard active else { return }
        if serverASR {
            maxListenItem?.cancel(); maxListenItem = nil
            stopVAD()
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
        stopVAD()
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
        stopVAD()
        maxListenItem?.cancel(); maxListenItem = nil
        recorder?.stop()
        let file = recURL
        recorder = nil
        recURL = nil
        upload(file)
    }

    private func upload(_ file: URL?) {
        guard let file = file else { onError?("录音文件丢失"); return }
        guard let base = serverURL, let data = try? Data(contentsOf: file),
              let url = URL(string: base + "/asr") else {
            // 电脑地址缺失/录音读不出来：本会话直接切回本机实时识别，不白录一趟
            serverASR = false
            cleanup(file)
            onError?("电脑转写不可用，已切回本机识别")
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
                        self.cleanup(file)
                        self.onError?("没听清，再说一次")
                    }
                } else {
                    // 电脑没接上 /asr（老版本 AgentShell 或断线）：本会话改用本机实时识别
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    self.serverASR = false
                    self.cleanup(file)
                    self.onError?("电脑转写不可用(\(code))，已切回本机识别")
                }
            }
        }.resume()
    }

    /// v2.3 简化：不再对录音文件做 Apple 离线识别（新 SDK 已移除 SFSpeechFileRecognitionRequest），
    /// 转写失败直接降级到本机实时通道
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
