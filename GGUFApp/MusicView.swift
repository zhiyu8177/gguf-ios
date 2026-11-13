import SwiftUI

/// 手机音乐页：手机出声，电脑不响。
/// 曲库来自电脑 music_srv（8321），点歌走 /resolve 取钥匙、AVPlayer 拉流播放。
struct MusicView: View {
    @ObservedObject var chatVM: ChatVM
    @StateObject private var m: MusicVM
    @Environment(\.presentationMode) private var dismiss

    init(chatVM: ChatVM) {
        self.chatVM = chatVM
        _m = StateObject(wrappedValue: MusicVM(serverProvider: { chatVM.server }))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                listArea
                playerBar
            }
            .background(T.bg.ignoresSafeArea())
            .navigationBarTitle("音乐 · 手机播放", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") { dismiss.wrappedValue.dismiss() })
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if !m.loaded { m.reload() }
        }
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(T.dim)
            TextField("搜歌名（曲库 \(m.tracks.isEmpty ? "加载中" : String(m.tracks.count)) 首）", text: $m.filter)
                .font(.system(size: 14))
                .foregroundColor(T.text)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !m.filter.isEmpty {
                Button(action: { m.filter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14)).foregroundColor(T.dim)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(red: 0.031, green: 0.071, blue: 0.133)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(T.line, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 列表

    private var listArea: some View {
        Group {
            if m.loading && m.tracks.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().accentColor(T.cyan)
                    Text("正在读曲库…").font(.system(size: 13)).foregroundColor(T.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !m.loaded {
                VStack(spacing: 12) {
                    Text(m.lastError.isEmpty ? "曲库未加载" : m.lastError)
                        .font(.system(size: 13)).foregroundColor(T.dim)
                        .multilineTextAlignment(.center)
                    Button("重试") { m.reload() }
                        .font(.system(size: 14))
                        .foregroundColor(T.cyan)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if m.filtered.isEmpty {
                Text("没有匹配「\(m.filter)」的歌")
                    .font(.system(size: 13)).foregroundColor(T.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.filtered) { t in
                            row(t)
                        }
                    }
                }
            }
        }
    }

    private func row(_ t: Track) -> some View {
        Button(action: { m.play(t) }) {
            HStack(spacing: 10) {
                Image(systemName: t.name == m.nowTitle && m.playing ? "waveform" : "music.note")
                    .font(.system(size: 13))
                    .foregroundColor(t.name == m.nowTitle ? T.cyan : T.dim)
                    .frame(width: 22)
                Text(t.name)
                    .font(.system(size: 14))
                    .foregroundColor(t.name == m.nowTitle ? T.cyan : T.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(T.line.opacity(0.6)), alignment: .bottom)
    }

    // MARK: - 播放条

    private var playerBar: some View {
        VStack(spacing: 0) {
            Rectangle().frame(height: 1).foregroundColor(T.line)

            if !m.lastError.isEmpty && m.loaded {
                Text(m.lastError)
                    .font(.system(size: 11)).foregroundColor(T.bad)
                    .padding(.top, 6)
            }

            HStack(spacing: 14) {
                // 连播开关
                Button(action: { m.autoNext.toggle() }) {
                    Image(systemName: m.autoNext ? "repeat.circle.fill" : "repeat.circle")
                        .font(.system(size: 20))
                        .foregroundColor(m.autoNext ? T.cyan : T.dim)
                }

                VStack(spacing: 2) {
                    Text(m.nowTitle.isEmpty ? (m.loading ? "取流中…" : "点上面的歌，手机直接放") : m.nowTitle)
                        .font(.system(size: 12))
                        .foregroundColor(m.nowTitle.isEmpty ? T.dim : T.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                }

                Button(action: { m.playRandom() }) {
                    ZStack {
                        Circle().stroke(m.loading ? T.line : T.line, lineWidth: 1.5)
                        if m.loading { ProgressView().accentColor(T.cyan) }
                        else { Image(systemName: "dice").font(.system(size: 15)).foregroundColor(T.text) }
                    }
                    .frame(width: 40, height: 40)
                }
                .disabled(m.loading || m.tracks.isEmpty)

                Button(action: { m.toggle() }) {
                    ZStack {
                        Circle().fill(T.blue).opacity(0.25)
                        Circle().stroke(T.blue, lineWidth: 1.5)
                        Image(systemName: m.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 16))
                            .foregroundColor(T.cyan)
                    }
                    .frame(width: 44, height: 44)
                }
                .disabled(m.nowTitle.isEmpty && m.tracks.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(T.barBg)
    }
}
