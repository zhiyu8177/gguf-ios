import Foundation
import Combine
import AVFoundation
import Speech

/// 语音输入：iPhone 本机识别（SFSpeechRecognizer），音频不出手机。
/// 用法：start() 开始收音 → stop() 松手结束 → onText 回调识别结果
final class VoiceIO: ObservableObject {

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var speechGranted = false
    private var lastPartial = ""
    private var active = false
    private var tapInstalled = false
    private var timeoutItem: DispatchWorkItem?

    /// 请求权限（麦克风 + 语音识别），首次调用会弹系统授权框
    func requestAuth(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            self.speechGranted = (st == .authorized)
            AVAudioSession.sharedInstance().requestRecordPermission { micOK in
                DispatchQueue.main.async { done(micOK && self.speechGranted) }
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
            try s.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            active = false
            onError?("麦克风被占用，稍后再试")
            return
        }

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

        task = rec.recognitionTask(with: req) { [weak self] result, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let r = result {
                    let t = r.bestTranscription.formattedString
                    if !t.isEmpty { self.lastPartial = t }
                    if r.isFinal {
                        self.finish(text: t, error: nil)
                    }
                } else if err != nil {
                    self.finish(text: self.lastPartial, error: err)
                }
            }
        }
    }

    /// 松手：停止收音，等识别回调
    func stop() {
        guard active else { return }
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

    private func finish(text: String, error: Error?) {
        guard active else { return }
        active = false
        timeoutItem?.cancel()
        timeoutItem = nil
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
