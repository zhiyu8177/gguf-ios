import Foundation
import AVFoundation

/// 曲库单曲（index 是电脑端 /library 的顺序号，resolve 用它取流钥匙）
struct Track: Identifiable, Equatable {
    let index: Int
    let name: String
    let rel: String
    var id: Int { index }
}

/// 手机端音乐播放：曲库拉取 + /resolve 取钥匙 + AVPlayer 拉流
/// 声音只在手机出，电脑不播放（resolve 不触发电脑端播放器）。
final class MusicVM: ObservableObject {

    @Published private(set) var tracks: [Track] = []
    @Published var filter: String = ""
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var lastError = ""
    @Published private(set) var nowTitle = ""
    @Published private(set) var playing = false
    /// 播完自动随机下一首
    @Published var autoNext = true

    private var player: AVPlayer?
    private var endObs: NSObjectProtocol?
    private var musicBase = ""                 // http://<电脑host>:8321
    private let serverProvider: () -> String   // 实时取 ChatVM.server（地址可改）

    init(serverProvider: @escaping () -> String) {
        self.serverProvider = serverProvider
    }

    deinit {
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
    }

    /// 从 8099 地址推音乐服务地址：同主机、换 8321 端口
    static func musicBase(from server: String) -> String {
        guard let u = URL(string: server), let host = u.host else { return "" }
        return "http://" + host + ":8321"
    }

    var filtered: [Track] {
        let k = filter.trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return tracks }
        return tracks.filter { $0.name.localizedCaseInsensitiveContains(k) }
    }

    // MARK: - 曲库

    func reload() {
        let base = MusicVM.musicBase(from: serverProvider())
        guard !base.isEmpty else {
            loaded = false; lastError = "电脑地址不对，先在设置里改"; return
        }
        musicBase = base
        guard let url = URL(string: base + "/library?limit=4000") else { return }
        loading = true
        lastError = ""
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                guard let d = data, err == nil,
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      (obj["ok"] as? Bool) == true,
                      let items = obj["items"] as? [[String: Any]] else {
                    self.loaded = false
                    self.lastError = "连不上电脑音乐服务（8321 端口）"
                    return
                }
                self.tracks = items.compactMap {
                    guard let idx = $0["index"] as? Int,
                          let name = $0["name"] as? String,
                          let rel = $0["rel"] as? String else { return nil }
                    return Track(index: idx, name: name, rel: rel)
                }
                self.loaded = self.tracks.isEmpty ? false : true
                if self.tracks.isEmpty { self.lastError = "曲库是空的" }
            }
        }.resume()
    }

    // MARK: - 播放

    /// 点歌：resolve（纯数字 index，避开中文路径编码）拿钥匙 → AVPlayer 拉流
    func play(_ t: Track) {
        if musicBase.isEmpty { musicBase = MusicVM.musicBase(from: serverProvider()) }
        guard !musicBase.isEmpty, let url = URL(string: musicBase + "/resolve?i=" + String(t.index)) else {
            lastError = "电脑地址不对"; return
        }
        loading = true
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                guard let d = data,
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      (obj["ok"] as? Bool) == true,
                      let key = obj["key"] as? String,
                      let title = obj["title"] as? String else {
                    self.lastError = "取流失败：电脑上没这首歌了？"
                    return
                }
                self.startStream(self.musicBase + "/stream?k=" + key, title: title)
            }
        }.resume()
    }

    /// 随机来一首（排除当前这首）
    func playRandom() {
        let pool = tracks
        guard !pool.isEmpty else { lastError = "曲库还没加载"; return }
        var t = pool.randomElement()!
        if pool.count > 1, t.name == nowTitle {
            while t.name == nowTitle { t = pool.randomElement()! }
        }
        play(t)
    }

    /// 播放/暂停切换
    func toggle() {
        guard player != nil, !nowTitle.isEmpty else { return playRandom() }
        if playing { player?.pause(); playing = false }
        else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play(); playing = true
        }
    }

    func stop() {
        player?.pause()
        player = nil
        playing = false
    }

    private func startStream(_ urlStr: String, title: String) {
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        guard let url = URL(string: urlStr) else { lastError = "流地址不对"; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { }
        let p = AVPlayer(url: url)
        player = p
        nowTitle = title
        playing = true
        lastError = ""
        p.play()
        // 播完自动接下一首（连播开关关了就停在原地）
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.autoNext { self.playRandom() }
            else { self.playing = false }
        }
    }
}
