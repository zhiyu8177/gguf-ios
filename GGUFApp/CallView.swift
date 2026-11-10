import SwiftUI
import AVFoundation

// MARK: - 通话状态

enum CallState {
    case listening   // 正在听用户说
    case thinking    // 已发给电脑，等回答
    case speaking    // 正在朗读回答
    case paused      // 静音/暂停
}

// MARK: - 电脑 TTS 播放器（带完成回调）

final class CallSpeaker: NSObject, AVAudioPlayerDelegate {
    var onDone: (() -> Void)?
    private var player: AVAudioPlayer?
    private var dead = false

    func speak(server: String, text: String, done: @escaping () -> Void) {
        dead = false
        onDone = done
        guard let url = URL(string: server + "/tts") else { done(); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            guard !self.dead, let data = data, err == nil,
                  (resp as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { self.fire() }
                return
            }
            DispatchQueue.main.async {
                guard !self.dead else { return }
                do {
                    self.player = try AVAudioPlayer(data: data)
                    self.player?.delegate = self
                    self.player?.play()
                } catch { self.fire() }
            }
        }.resume()
    }

    /// 挂断/打断用：停止播放且不再触发回调
    func kill() {
        dead = true
        onDone = nil
        player?.stop()
        player = nil
    }

    private func fire() {
        let f = onDone
        onDone = nil
        f?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        fire()
    }
}

// MARK: - 通话逻辑（免提循环：听你说 → 发电脑 → 朗读回答 → 继续听）

final class CallVM: ObservableObject {

    @Published var state: CallState = .listening
    @Published var liveText = ""      // 聆听时你正在说的话（半截识别）
    @Published var lastReply = ""     // 最近一轮回答（小字展示）
    @Published var elapsed: TimeInterval = 0
    @Published var hint = ""          // 出错提示

    let chat: ChatVM
    private let voice = VoiceIO()
    private var speaker: CallSpeaker?
    private var tick: Timer?
    private var retryItem: DispatchWorkItem?
    private var errStreak = 0
    private var stopped = false

    init(chat: ChatVM) {
        self.chat = chat
        chat.autoRead = false        // 通话页自己管朗读，避免双重朗读
        chat.stopSpeaking()
        voice.maxListenSeconds = 15
        voice.onPartial = { [weak self] t in self?.liveText = t }
        voice.onText = { [weak self] t in self?.userSaid(t) }
        voice.onError = { [weak self] _ in self?.scheduleListenRetry() }
        chat.onReplyDone = { [weak self] reply in self?.aiReplied(reply) }

        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true, options: .notifyOthersOnDeactivation)

        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsed += 1
        }
        beginListening()
    }

    deinit { hangUp() }

    // MARK: 听

    private func beginListening() {
        guard !stopped else { return }
        state = .listening
        liveText = ""
        voice.requestAuth { [weak self] ok in
            guard let self = self, !self.stopped else { return }
            guard ok else {
                self.hint = "需要麦克风+语音识别权限：设置 → GGUF"
                self.state = .paused
                return
            }
            self.voice.start()
        }
    }

    /// 识别出错/没听清：缓一下重开聆听，连续错太多次就暂停等人按麦克风
    private func scheduleListenRetry() {
        guard !stopped else { return }
        errStreak += 1
        if errStreak >= 4 {
            hint = "连续几次没听清，先暂停了"
            state = .paused
            errStreak = 0
            return
        }
        retryItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.beginListening() }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    // MARK: 你说了一句

    private func userSaid(_ t: String) {
        guard !stopped else { return }
        errStreak = 0
        guard !chat.busy else {
            scheduleListenRetry()      // 引擎忙（理论上不会走到，兜底）
            return
        }
        state = .thinking
        chat.send(t)
    }

    // MARK: 电脑答完

    private func aiReplied(_ reply: String) {
        guard !stopped, state == .thinking else { return }
        guard !reply.isEmpty else {
            hint = "电脑没答上来，再说一次"
            scheduleListenRetry()
            return
        }
        lastReply = reply
        state = .speaking
        let sp = CallSpeaker()
        speaker = sp
        sp.speak(server: chat.server, text: reply) { [weak self, weak sp] in
            guard let self = self, !self.stopped else { return }
            if sp !== self.speaker { return }
            self.beginListening()
        }
    }

    // MARK: 控制

    func toggleMute() {
        guard !stopped else { return }
        if state == .paused {
            hint = ""
            errStreak = 0
            beginListening()
        } else {
            voice.abort()
            speaker?.kill()
            speaker = nil
            state = .paused
        }
    }

    func hangUp() {
        guard !stopped else { return }
        stopped = true
        voice.abort()
        speaker?.kill()
        speaker = nil
        tick?.invalidate()
        tick = nil
        retryItem?.cancel()
        chat.onReplyDone = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - 通话界面入口（负责持有 CallVM）

struct CallScreen: View {
    @StateObject private var vm: CallVM
    init(chat: ChatVM) {
        _vm = StateObject(wrappedValue: CallVM(chat: chat))
    }
    var body: some View { CallView(vm: vm) }
}

// MARK: - 通话界面（豆包式全屏）

struct CallView: View {
    @ObservedObject var vm: CallVM
    @Environment(\.presentationMode) private var dismiss

    var body: some View {
        ZStack {
            // 深色渐变背景
            LinearGradient(gradient: Gradient(colors: [Color(red: 0.01, green: 0.03, blue: 0.06),
                                    Color(red: 0.03, green: 0.07, blue: 0.14),
                                    Color(red: 0.01, green: 0.03, blue: 0.07)]),
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                avatarArea
                Spacer()
                transcript
                controls
            }
        }
        .onDisappear { vm.hangUp() }
    }

    // MARK: 顶栏：通话时长 + 挂断提示

    private var topBar: some View {
        VStack(spacing: 4) {
            Text("AgentShell · 免提通话")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(T.text)
            Text(timeString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(T.dim)
        }
        .padding(.top, 14)
    }

    private var timeString: String {
        let s = Int(vm.elapsed)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: 中间大圆（随状态变色 + 呼吸动画）

    private var avatarArea: some View {
        VStack(spacing: 22) {
            PulsingOrb(state: vm.state)
            Text(statusText)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(T.text)
        }
    }

    private var statusText: String {
        switch vm.state {
        case .listening: return vm.liveText.isEmpty ? "在听你说…" : ""
        case .thinking:  return "思考中…"
        case .speaking:  return "正在回答"
        case .paused:    return "已暂停，按麦克风继续"
        }
    }

    // MARK: 文字展示区（你说的 / 它答的）

    private var transcript: some View {
        VStack(spacing: 10) {
            if !vm.liveText.isEmpty && vm.state == .listening {
                Text(vm.liveText)
                    .font(.system(size: 14))
                    .foregroundColor(T.dim)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            if vm.state == .speaking {
                Text(vm.lastReply)
                    .font(.system(size: 14))
                    .foregroundColor(T.text.opacity(0.75))
                    .lineLimit(5)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            if !vm.hint.isEmpty {
                Text(vm.hint)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.3))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .frame(minHeight: 60)
    }

    // MARK: 底部三键：静音 / 挂断 / 回到打字

    private var controls: some View {
        HStack(spacing: 34) {
            // 静音 / 继续听
            Button(action: { vm.toggleMute() }) {
                ZStack {
                    Circle().fill(T.barBg)
                    Circle().stroke(vm.state == .paused ? T.cyan : T.line, lineWidth: 1.5)
                    Image(systemName: vm.state == .paused ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 20))
                        .foregroundColor(T.text)
                }
                .frame(width: 62, height: 62)
            }

            // 挂断
            Button(action: { dismiss.wrappedValue.dismiss() }) {
                ZStack {
                    Circle().fill(T.bad)
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 78, height: 78)
                .shadow(color: T.bad.opacity(0.45), radius: 12)
            }

            // 回到文字聊天
            Button(action: { dismiss.wrappedValue.dismiss() }) {
                ZStack {
                    Circle().fill(T.barBg)
                    Circle().stroke(T.line, lineWidth: 1.5)
                    Image(systemName: "keyboard")
                        .font(.system(size: 20))
                        .foregroundColor(T.text)
                }
                .frame(width: 62, height: 62)
            }
        }
        .padding(.bottom, 44)
    }
}

// MARK: - 呼吸大圆

struct PulsingOrb: View {
    let state: CallState
    @State private var pulse: CGFloat = 0

    private var coreColor: Color {
        switch state {
        case .listening: return T.cyan
        case .thinking:  return T.blue
        case .speaking:  return T.ok
        case .paused:    return T.dim
        }
    }

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(coreColor.opacity(0.28 - Double(i) * 0.08), lineWidth: 1.5)
                    .frame(width: 170 + CGFloat(i) * 34, height: 170 + CGFloat(i) * 34)
                    .scaleEffect(1 + pulse * (state == .paused ? 0 : 0.12))
                    .opacity(state == .paused ? 0.4 : 1)
                    .animation(.easeInOut(duration: 1.6 + Double(i) * 0.4).repeatForever(autoreverses: true))
            }
            Circle()
                .fill(RadialGradient(gradient: Gradient(colors: [coreColor.opacity(0.9), coreColor.opacity(0.35)]),
                                     center: .center, startRadius: 4, endRadius: 76))
                .frame(width: 148, height: 148)
            Image(systemName: state == .paused ? "mic.slash.fill" : "waveform")
                .font(.system(size: 40, weight: .medium))
                .foregroundColor(Color(red: 0.02, green: 0.05, blue: 0.1))
        }
        .onAppear { pulse = 1 }
    }
}
