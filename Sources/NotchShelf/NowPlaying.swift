import AppKit

struct TrackInfo: Equatable {
    enum Source: Equatable { case mediaRemote, music, spotify }

    var title: String
    var artist: String
    var artwork: NSImage?
    var isPlaying: Bool
    var source: Source

    var key: String { title + "|" + artist }

    static func == (a: TrackInfo, b: TrackInfo) -> Bool {
        a.title == b.title && a.artist == b.artist && a.isPlaying == b.isPlaying
            && a.source == b.source && a.artwork === b.artwork
    }
}

/// «Сейчас играет»: системный MediaRemote (любой плеер, если macOS разрешает),
/// иначе — Музыка и Spotify через AppleScript.
@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var track: TrackInfo?

    private let settings: AppSettings
    private let scriptQueue = DispatchQueue(label: "notchshelf.applescript")
    private var timer: Timer?
    private var artworkCache: (key: String, image: NSImage?)?
    private var requestToken = 0
    private var answeredToken = 0

    init(settings: AppSettings) {
        self.settings = settings
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    // MARK: Обновление

    func refresh() {
        guard settings.showNowPlaying else {
            if track != nil { track = nil }
            return
        }
        requestToken += 1
        let token = requestToken

        MediaRemoteBridge.shared.fetch { [weak self] info in
            MainActor.assumeIsolated {
                guard let self, token == self.requestToken, self.answeredToken != token else { return }
                self.answeredToken = token
                if let info { self.apply(info) } else { self.refreshViaAppleScript() }
            }
        }
        // На новых macOS MediaRemote может молчать — не ждём его дольше полсекунды
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.requestToken, self.answeredToken != token else { return }
                self.answeredToken = token
                self.refreshViaAppleScript()
            }
        }
    }

    private func refreshViaAppleScript() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var sources: [TrackInfo.Source] = []
        if running.contains("com.spotify.client") { sources.append(.spotify) }
        if running.contains("com.apple.Music") { sources.append(.music) }
        guard !sources.isEmpty else {
            apply(nil)
            return
        }
        scriptQueue.async { [weak self] in
            var best: TrackInfo?
            for s in sources {
                guard let t = Self.query(s) else { continue }
                if t.isPlaying { best = t; break }
                if best == nil { best = t }
            }
            let result = best
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(result) }
            }
        }
    }

    private func apply(_ info: TrackInfo?) {
        guard var info else {
            if track != nil { track = nil }
            return
        }
        if info.artwork == nil {
            if let cache = artworkCache, cache.key == info.key {
                info.artwork = cache.image
            } else if info.source != .mediaRemote {
                loadArtwork(for: info)
            }
        } else {
            artworkCache = (info.key, info.artwork)
        }
        if track != info { track = info }
    }

    private func loadArtwork(for info: TrackInfo) {
        artworkCache = (info.key, nil)
        let key = info.key
        let source = info.source
        scriptQueue.async { [weak self] in
            let finish: @Sendable (NSImage?) -> Void = { image in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.artworkCache?.key == key else { return }
                        self.artworkCache = (key, image)
                        if self.track?.key == key { self.track?.artwork = image }
                    }
                }
            }
            if source == .music {
                let script = "tell application \"Music\" to return raw data of artwork 1 of current track"
                let data = Self.run(script)?.data
                finish(data.flatMap { NSImage(data: $0) })
            } else {
                let script = "tell application \"Spotify\" to return artwork url of current track"
                guard let s = Self.run(script)?.stringValue,
                      let url = URL(string: s) else { finish(nil); return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    finish(data.flatMap { NSImage(data: $0) })
                }.resume()
            }
        }
    }

    nonisolated private static func query(_ source: TrackInfo.Source) -> TrackInfo? {
        let app = source == .spotify ? "Spotify" : "Music"
        let script = """
        tell application "\(app)"
            if player state is stopped then return ""
            set t to name of current track
            set a to artist of current track
            set s to player state as string
            return t & linefeed & a & linefeed & s
        end tell
        """
        guard let out = run(script)?.stringValue,
              !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 3, !parts[0].isEmpty else { return nil }
        return TrackInfo(title: parts[0], artist: parts[1], artwork: nil,
                         isPlaying: parts[2] == "playing", source: source)
    }

    /// Безопасный запуск AppleScript: при ошибке возвращает nil.
    nonisolated private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    // MARK: Управление

    func playPause() {
        command(mediaRemote: 2, script: "playpause")
        if track != nil { track?.isPlaying.toggle() }
    }

    func next() { command(mediaRemote: 4, script: "next track") }
    func previous() { command(mediaRemote: 5, script: "previous track") }

    func openPlayer() {
        guard let track else { return }
        let id: String? = track.source == .spotify ? "com.spotify.client"
            : track.source == .music ? "com.apple.Music" : nil
        if let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func command(mediaRemote cmd: UInt32, script: String) {
        guard let track else { return }
        switch track.source {
        case .mediaRemote:
            _ = MediaRemoteBridge.shared.send(cmd)
        case .spotify, .music:
            let app = track.source == .spotify ? "Spotify" : "Music"
            scriptQueue.async {
                _ = Self.run("tell application \"\(app)\" to \(script)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

/// Мост к приватному фреймворку MediaRemote (тот же, что использует Пункт управления).
final class MediaRemoteBridge: @unchecked Sendable {
    static let shared = MediaRemoteBridge()

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private var getInfo: GetInfoFn?
    private var sendCommand: SendFn?

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else { return }
        if let p = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") { getInfo = unsafeBitCast(p, to: GetInfoFn.self) }
        if let p = dlsym(handle, "MRMediaRemoteSendCommand") { sendCommand = unsafeBitCast(p, to: SendFn.self) }
    }

    /// Возвращает трек или nil (в т.ч. если macOS не отдаёт данные сторонним приложениям).
    func fetch(_ completion: @escaping (TrackInfo?) -> Void) {
        guard let getInfo else { completion(nil); return }
        getInfo(DispatchQueue.main) { dict in
            guard let dict, let d = (dict as NSDictionary) as? [String: Any],
                  let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
                completion(nil)
                return
            }
            let artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            let art = (d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap { NSImage(data: $0) }
            completion(TrackInfo(title: title, artist: artist, artwork: art, isPlaying: rate > 0, source: .mediaRemote))
        }
    }

    func send(_ command: UInt32) -> Bool {
        sendCommand?(command, nil) ?? false
    }
}
