import SwiftUI

// 深色主题色板（对齐原壳观感）
enum T {
    static let bg      = Color(red: 0.016, green: 0.027, blue: 0.059)
    static let line    = Color(red: 0.071, green: 0.157, blue: 0.239)
    static let text    = Color(red: 0.843, green: 0.925, blue: 1.0)
    static let dim     = Color(red: 0.435, green: 0.576, blue: 0.722)
    static let cyan    = Color(red: 0.0,   green: 0.784, blue: 1.0)
    static let blue    = Color(red: 0.102, green: 0.427, blue: 1.0)
    static let ok      = Color(red: 0.208, green: 0.878, blue: 0.631)
    static let bad     = Color(red: 1.0,   green: 0.42,  blue: 0.506)
    static let barBg   = Color(red: 0.055, green: 0.11,  blue: 0.19)
    static let holdBg  = Color(red: 0.07,  green: 0.19,  blue: 0.31)
    static let holdRec = Color(red: 0.24,  green: 0.08,  blue: 0.14)
}

struct ChatView: View {
    @StateObject private var vm = ChatVM()
    @StateObject private var voice = VoiceIO()

    @State private var showSettings = false
    @State private var holding = false
    @State private var toastText: String = ""
    @State private var toastOn = false

    var body: some View {
        ZStack(alignment: .bottom) {
            T.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                chatList
                inputBar
            }

            if toastOn {
                Text(toastText)
                    .font(.system(size: 12))
                    .foregroundColor(T.cyan)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(T.barBg))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(T.line, lineWidth: 1))
                    .padding(.bottom, 120)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: setup)
        .sheet(isPresented: $showSettings) { SettingsView(vm: vm) }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 6) {
            Text("AgentShell 直连")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(T.text)
            Text("v2.1").font(.system(size: 10)).foregroundColor(T.dim)

            Spacer()

            dot(vm.engineOK); Text("引擎").font(.system(size: 10)).foregroundColor(T.dim)
            dot(vm.ttsOK).padding(.leading, 6); Text("语音").font(.system(size: 10)).foregroundColor(T.dim)

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundColor(T.dim)
            }.padding(.leading, 6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(T.barBg)
        .overlay(Rectangle().frame(height: 1).foregroundColor(T.line), alignment: .bottom)
    }

    private func dot(_ on: Bool) -> some View {
        Circle()
            .fill(on ? T.ok : T.bad)
            .frame(width: 7, height: 7)
            .shadow(color: on ? T.ok.opacity(0.8) : .clear, radius: 3)
    }

    // MARK: - 消息列表

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.msgs) { m in
                        BubbleView(m: m).id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .onChange(of: vm.msgs.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.msgs.last?.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - 输入区（微信式：点喇叭切语音模式，实心条按住说话）

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button(action: toggleVoiceMode) {
                ZStack {
                    Circle().fill(vm.voiceMode ? Color(red: 0.05, green: 0.13, blue: 0.21) : T.barBg)
                    Circle().stroke(vm.voiceMode ? T.blue : T.line, lineWidth: 1.5)
                    Image(systemName: vm.voiceMode ? "keyboard" : "mic.fill")
                        .font(.system(size: 17))
                        .foregroundColor(vm.voiceMode ? T.cyan : T.dim)
                }
                .frame(width: 44, height: 44)
            }

            if vm.voiceMode {
                holdBar
            } else {
                TextField("说点什么…", text: $vm.input)
                    .font(.system(size: 15))
                    .foregroundColor(T.text)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.031, green: 0.071, blue: 0.133)))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(T.line, lineWidth: 1))
                    .accentColor(T.cyan)
            }

            if !vm.voiceMode {
                Button(action: { vm.send(vm.input) }) {
                    ZStack {
                        Circle().fill(T.barBg)
                        Circle().stroke(vm.busy ? T.line : T.blue, lineWidth: 1.5)
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16))
                            .foregroundColor(vm.busy ? T.dim : T.cyan)
                    }
                    .frame(width: 44, height: 44)
                }
                .disabled(vm.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(T.barBg)
        .overlay(Rectangle().frame(height: 1).foregroundColor(T.line), alignment: .top)
    }

    private var holdBar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(holding ? T.holdRec : T.holdBg)
            RoundedRectangle(cornerRadius: 22)
                .stroke(holding ? T.bad : T.line, lineWidth: 1)
            HStack(spacing: 8) {
                Text(holding ? "松开 发送" : "按住 说话")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(holding ? Color(red: 1.0, green: 0.7, blue: 0.76) : T.text)
                if holding { RecDots() }
            }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHold() }
                .onEnded { _ in endHold() }
        )
    }

    // MARK: - 行为

    private func setup() {
        vm.start()
        voice.requestAuth { _ in }
        voice.onText = { t in
            holding = false
            if vm.busy {
                vm.input = t
                vm.voiceMode = false
                toast("上一轮还没答完，先填进输入框")
            } else {
                vm.send(t)
            }
        }
        voice.onError = { e in
            holding = false
            toast(e)
        }
    }

    private func toggleVoiceMode() {
        guard !holding else { return }
        vm.voiceMode.toggle()
        if vm.voiceMode { toast("按住实心条说话，松手自动发送") }
    }

    private func beginHold() {
        guard vm.voiceMode, !holding, !vm.busy else { return }
        holding = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voice.requestAuth { ok in
            guard ok else {
                holding = false
                toast("需要麦克风 + 语音识别权限：设置 → GGUF")
                return
            }
            voice.start()
        }
    }

    private func endHold() {
        guard holding else { return }
        holding = false
        voice.stop()
    }

    private func toast(_ s: String) {
        toastText = s
        withAnimation { toastOn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { toastOn = false }
        }
    }
}

// MARK: - 气泡

struct BubbleView: View {
    let m: Msg

    var body: some View {
        HStack {
            if m.role == .user { Spacer(minLength: 40) }
            Text(m.text + (m.streaming ? " ▍" : ""))
                .font(.system(size: 15))
                .foregroundColor(m.role == .sys ? T.dim : T.text)
                .padding(.horizontal, m.role == .sys ? 0 : 14)
                .padding(.vertical, m.role == .sys ? 0 : 11)
                .background(bg)
                .cornerRadius(14)
            if m.role != .user { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var bg: some View {
        if m.role == .sys {
            Color.clear
        } else if m.role == .user {
            RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.165, blue: 0.29))
        } else {
            RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.05, green: 0.1, blue: 0.18))
        }
    }
}

/// 录音时的跳动小点
struct RecDots: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(T.bad)
                    .frame(width: 3, height: 4 + abs(sin(phase + CGFloat(i))) * 10)
            }
        }
        .frame(height: 16)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var vm: ChatVM
    @Environment(\.presentationMode) private var dismiss
    @State private var addr: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("电脑地址")) {
                    TextField(ChatVM.defaultServer, text: $addr)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("保存并重连") {
                        vm.saveServer(addr)
                        dismiss.wrappedValue.dismiss()
                    }
                    Button("恢复默认（\(ChatVM.defaultServer)）") {
                        addr = ChatVM.defaultServer
                        vm.saveServer(addr)
                    }.foregroundColor(.orange)
                }

                Section(header: Text("状态")) {
                    HStack {
                        Text("当前地址"); Spacer()
                        Text(vm.server).font(.system(size: 12)).foregroundColor(.gray)
                    }
                    HStack {
                        Text("引擎"); Spacer()
                        Text(vm.engineOK ? "在线" : "未连接").foregroundColor(vm.engineOK ? .green : .red)
                    }
                    HStack {
                        Text("语音朗读"); Spacer()
                        Text(vm.ttsOK ? "可用" : "不可用").foregroundColor(vm.ttsOK ? .green : .red)
                    }
                    Toggle("回答自动朗读", isOn: $vm.autoRead)
                }

                Section(header: Text("连不上时检查"), footer: Text("1. 电脑端 AgentShell 是否在运行（手机通道显示运行中）\n2. 手机与电脑是否都在蒲公英组网内\n3. 设置 → 隐私与安全性 → 本地网络 → 打开 GGUF\n4. 设置 → GGUF → 麦克风 / 语音识别 允许")) {
                    EmptyView()
                }
            }
            .navigationBarTitle("设置", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") { dismiss.wrappedValue.dismiss() })
        }
        .onAppear { addr = vm.server }
    }
}

// MARK: - 入口

@main
struct GGUFAppMain: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}
