import SwiftUI
import WebKit
import AVKit
import MediaPlayer

struct Video: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var channel: String = ""
    var detail: String = ""
    var duration: String = ""
    var channelID: String? = nil
    var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

extension Video {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        channel = try container.decodeIfPresent(String.self, forKey: .channel) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        duration = try container.decodeIfPresent(String.self, forKey: .duration) ?? ""
        let channelValue = try container.decodeIfPresent(String.self, forKey: .channelID)
        channelID = channelValue?.isEmpty == false ? channelValue : nil
    }
}

enum FeedTab: String, CaseIterable { case home = "Home", subscriptions = "Following", library = "Library" }
struct CaptionTrack: Identifiable, Decodable, Equatable {
    let id: String
    let language: String
    let name: String
}

@MainActor final class YouTubeEngine: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVPlayerViewControllerDelegate {
    @Published var videos: [Video] = []
    @Published var history: [Video] = []
    @Published var current: Video?
    @Published var tab: FeedTab = .home
    @Published var loading = true
    @Published var message: String?
    @Published var playerMessage: String?
    @Published var showBrowser = false
    @Published var inlinePlayerVisible = false { didSet { updateIdleTimer() } }
    private var nativePictureInPicture = false
    private var webPictureInPicture = false
    @Published var playing = false { didSet { updateIdleTimer() } }
    @Published var startingPlayback = false { didSet { updateIdleTimer() } }
    @Published var elapsed = 0.0
    @Published var duration = 0.0
    @Published var nativeActive = false
    @Published var fullScreen = false
    @Published var muted = false
    @Published var playbackSpeed = UserDefaults.standard.object(forKey: "playbackSpeed") as? Double ?? 1
    @Published var captionTracks: [CaptionTrack] = []
    @Published var selectedCaptionID = ""
    @Published var captionsLoaded = false
    private var captionsEnabled = UserDefaults.standard.bool(forKey: "captionsEnabled")
    private var captionLanguage = UserDefaults.standard.string(forKey: "captionLanguage") ?? "en"
    private var preferredCaptionID = ""
    private var nativeCaptionGroup: AVMediaSelectionGroup?
    static let playbackSpeeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    var captionSummary: String { captionTracks.first { $0.id == selectedCaptionID }?.name ?? "Off" }
    @Published var adsSkipped = 0
    @Published var blockerReady = false
    @Published var blockerError: String?
    @Published var query = ""
    @Published var discoveryMode = false
    @Published var signedOut = true
    @Published var subscriptionFeed = false
    private var feedRevision = 0
    @Published var blockAds = UserDefaults.standard.object(forKey: "blockAds") as? Bool ?? true
    @Published var backgroundAudio = UserDefaults.standard.object(forKey: "backgroundAudio") as? Bool ?? true
    let feedWeb: WKWebView
    let playerWeb: WKWebView
    let player = AVPlayer()
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var attemptedStream: String?
    private var feedTimeout: Task<Void, Never>?
    private var streamTimeout: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var isConfigured = false
    private var lastFeedURL: URL = URL(string: "https://m.youtube.com/")!
    private var pendingOpen: URL?
    private var playbackRequested = false
    private var ownsNativeAudioSession = false
    private let playbackDiagnostics = ProcessInfo.processInfo.arguments.contains("--playback-diagnostics")
    private var playbackTrace: [String] = []
    private var transportObservation: NSKeyValueObservation?
    func updateIdleTimer() {
        let watching = inlinePlayerVisible && (playing || startingPlayback) && UIApplication.shared.applicationState == .active
        if UIApplication.shared.isIdleTimerDisabled != watching {
            UIApplication.shared.isIdleTimerDisabled = watching
            tracePlayback("idleTimer", ["disabled": watching])
        }
    }
    #if targetEnvironment(simulator)
    private var simulatedInterruptionVideo: String?
    #endif
    private func offlinePlaybackURL(_ id: String) -> URL? {
        #if targetEnvironment(simulator)
        if id == "aqz-KE-bpKQ", let path = ProcessInfo.processInfo.environment["BETTER_YOUTUBE_TEST_VIDEO"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        #endif
        return OfflineLibrary.shared.localURL(id)
    }

    func tracePlayback(_ event: String, _ values: [String: Any] = [:]) {
        guard playbackDiagnostics else { return }
        var row = values
        row["event"] = event; row["timestamp"] = Date().timeIntervalSince1970
        row["native"] = nativeActive; row["requested"] = playbackRequested; row["ownsAudio"] = ownsNativeAudioSession
        guard let data = try? JSONSerialization.data(withJSONObject: row), let line = String(data: data, encoding: .utf8) else { return }
        playbackTrace.append(line); playbackTrace = Array(playbackTrace.suffix(500))
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("playback-diagnostics.jsonl")
        try? (playbackTrace.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    override init() {
        func web() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.allowsInlineMediaPlayback = true
            config.allowsPictureInPictureMediaPlayback = true
            config.allowsAirPlayForMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            config.preferences.isElementFullscreenEnabled = true
            let view = WKWebView(frame: .zero, configuration: config)
            view.isOpaque = false
            view.backgroundColor = .black
            view.scrollView.backgroundColor = .black
            view.allowsBackForwardNavigationGestures = true
            view.isInspectable = true
            return view
        }
        feedWeb = web(); playerWeb = web()
        super.init()
        history = readVideos("history")
        for web in [feedWeb, playerWeb] {
            web.navigationDelegate = self; web.uiDelegate = self
            web.configuration.userContentController.add(WeakScriptHandler(self), name: "betterYouTube")
        }
        player.audiovisualBackgroundPlaybackPolicy = backgroundAudio ? .continuesIfPossible : .pauses
        transportObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus.rawValue
            Task { @MainActor in self?.tracePlayback("nativeTransport", ["status": status]) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.nativeActive else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                let d = self.player.currentItem?.duration.seconds ?? 0
                self.duration = d.isFinite ? d : 0
                self.playing = self.player.timeControlStatus == .playing
                self.startingPlayback = self.playbackRequested && self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if self.player.rate > 0 { self.playbackSpeed = Double(self.player.rate) }
                self.readNativeCaptionSelection()
                self.updateNowPlaying()
            }
        }
        installRemoteCommands()
        observations.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            Task { @MainActor in
                self?.tracePlayback("audioInterruption", ["type": type ?? 99, "reason": reason])
                // WKWebView has its own media audio session. Its audible startup
                // can interrupt the host session; that must not pause WebKit.
                guard let self, self.nativeActive, self.ownsNativeAudioSession else {
                    self?.tracePlayback("ignoredHostInterruption"); return
                }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.pause(reason: "audioInterruption") }
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.tracePlayback("audioRoute", ["reason": reason ?? 99])
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause(reason: "audioRoute") }
            }
        })
        Task { await configure(); if let url = pendingOpen { pendingOpen = nil; open(url) } else { selectTab(tab) } }
    }

    private func readVideos(_ key: String) -> [Video] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Video].self, from: data)) ?? []
    }
    private func persist(_ videos: [Video], _ key: String) { UserDefaults.standard.set(try? JSONEncoder().encode(videos), forKey: key) }

    func configure() async {
        isConfigured = false
        let source = (try? String(contentsOf: Bundle.main.url(forResource: "YouTubeBridge", withExtension: "js")!, encoding: .utf8)) ?? ""
        for (web, role) in [(feedWeb, "feed"), (playerWeb, "player")] {
            let controller = web.configuration.userContentController
            controller.removeAllUserScripts()
            controller.removeAllContentRuleLists()
            let config = "window.BetterYouTubeConfig = {role:'\(role)',blockAds:\(blockAds),background:\(backgroundAudio),diagnostics:\(playbackDiagnostics)};\n"
            controller.addUserScript(WKUserScript(source: config + source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        blockerReady = false
        if blockAds {
            let rules = #"[{"trigger":{"url-filter":"doubleclick\\.net"},"action":{"type":"block"}},{"trigger":{"url-filter":"googlesyndication\\.com"},"action":{"type":"block"}},{"trigger":{"url-filter":"googleadservices\\.com"},"action":{"type":"block"}},{"trigger":{"url-filter":"youtube\\.com/api/stats/ads"},"action":{"type":"block"}},{"trigger":{"url-filter":"youtube\\.com/pagead/"},"action":{"type":"block"}}]"#
            do {
                let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BetterYouTubeAds-v1", encodedContentRuleList: rules)
                if let list { for web in [feedWeb, playerWeb] { web.configuration.userContentController.add(list) }; blockerReady = true; blockerError = nil }
            } catch { blockerError = error.localizedDescription; message = "The ad filter could not load. You can retry in Settings." }
        }
        player.audiovisualBackgroundPlaybackPolicy = backgroundAudio ? .continuesIfPossible : .pauses
        isConfigured = true
    }

    func applySettings() {
        UserDefaults.standard.set(blockAds, forKey: "blockAds")
        UserDefaults.standard.set(backgroundAudio, forKey: "backgroundAudio")
        Task { await configure(); refresh(); if current != nil && !nativeActive { playerWeb.reload() } }
    }
    func loadHome() { if tab != .home { dismissInlinePlayer() }; query = ""; tab = .home; discoveryMode = false; subscriptionFeed = false; loadFeed(URL(string: "https://m.youtube.com/")!) }
    func loadDiscovery() {
        guard tab == .home, query.isEmpty, !showBrowser, !discoveryMode else { return }
        discoveryMode = true
        let rules = YouTubeAccount.shared.subscriptions.isEmpty ? OfflineLibrary.shared.channels : YouTubeAccount.shared.subscriptions
        if !rules.isEmpty { loadChannelFeed(rules); return }
        var components = URLComponents(string: "https://m.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: history.first?.channel.isEmpty == false ? history[0].channel : "popular science technology music")]
        loadFeed(components.url!)
    }
    func tapTab(_ newTab: FeedTab) {
        if tab == newTab && inlinePlayerVisible {
            dismissInlinePlayer()
            return
        }
        selectTab(newTab)
    }
    func selectTab(_ newTab: FeedTab) {
        if tab != newTab { dismissInlinePlayer() }
        tab = newTab; showBrowser = false; query = ""
        if newTab == .home { loadHome() }
        if newTab == .subscriptions { loadFollowing() }
        if newTab == .library { feedRevision += 1; feedTimeout?.cancel(); feedWeb.stopLoading(); loading = false }
    }
    private func loadFollowing() {
        feedRevision += 1; feedTimeout?.cancel(); feedWeb.stopLoading()
        subscriptionFeed = true; discoveryMode = false; videos = []; message = nil; loading = false
        let account = YouTubeAccount.shared
        // Website cookies and manually followed channels do not establish Google authorization.
        guard account.signedIn else { return }
        if !account.subscriptions.isEmpty { loadChannelFeed(account.subscriptions); return }
        loading = true
        let revision = feedRevision
        Task {
            await account.refreshSubscriptions()
            guard revision == feedRevision, tab == .subscriptions, account.signedIn else { return }
            if !account.subscriptions.isEmpty { loadChannelFeed(account.subscriptions) }
            else { loading = false; message = account.error ?? "You haven’t subscribed to any channels yet." }
        }
    }
    func loadChannelFeed(_ rules: [ChannelRule]) {
        subscriptionFeed = true; loading = true; videos = []; message = nil; feedTimeout?.cancel(); feedWeb.stopLoading(); feedRevision += 1
        let revision = feedRevision
        Task {
            let items = await ChannelVideoFeed.load(rules)
            guard revision == feedRevision else { return }
            videos = items; loading = false
            if items.isEmpty { message = "Couldn’t load recent uploads. Pull to refresh when you’re online." }
        }
    }
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), Self.videoID(url) != nil { open(url); return }
        if tab != .home { dismissInlinePlayer() }
        query = trimmed; tab = .home; showBrowser = false; discoveryMode = false; subscriptionFeed = false
        var components = URLComponents(string: "https://m.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: trimmed)]
        loadFeed(components.url!)
    }
    func loadFeed(_ url: URL) {
        lastFeedURL = url; videos = []; message = nil; loading = true
        feedRevision += 1
        let revision = feedRevision
        feedWeb.load(URLRequest(url: url))
        feedTimeout?.cancel()
        feedTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.feedRevision == revision else { return }
            self.loading = false
            if self.videos.isEmpty && self.tab == .home && self.query.isEmpty && !self.discoveryMode && !self.showBrowser { self.loadDiscovery(); return }
            if self.videos.isEmpty { self.message = "YouTube hasn’t returned videos yet. Try a search, or open YouTube to sign in or review a prompt." }
        }
    }
    func refresh() {
        if tab == .subscriptions { loadFollowing() }
        else if tab == .home {
            if subscriptionFeed { loadChannelFeed(YouTubeAccount.shared.subscriptions.isEmpty ? OfflineLibrary.shared.channels : YouTubeAccount.shared.subscriptions) }
            else { loadFeed(lastFeedURL) }
        }
    }
    func loadMore() { feedWeb.evaluateJavaScript("window.BetterYouTube?.more()", completionHandler: nil) }
    func finishBrowsing() { showBrowser = false; if tab == .subscriptions { selectTab(.subscriptions) } else { loadHome() } }

    static func videoID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        var id: String?
        if host == "youtu.be" { id = url.pathComponents.dropFirst().first }
        else if host == "youtube.com" || host.hasSuffix(".youtube.com") || url.scheme == "betteryoutube" {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
            if id == nil && (url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/embed/")) { id = url.pathComponents.last }
        }
        guard let id, id.range(of: "^[a-zA-Z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        return id
    }
    func open(_ url: URL) {
        guard isConfigured else { pendingOpen = url; return }
        guard let id = Self.videoID(url) else { message = "Paste a YouTube video link or search for a video."; return }
        play(Video(id: id, title: "YouTube video"))
    }
    func play(_ video: Video) {
        tracePlayback("selectVideo", ["id": video.id, "tab": tab.rawValue])
        pause(reason: "replaceVideo"); streamTimeout?.cancel(); statusObservation = nil; player.replaceCurrentItem(with: nil)
        releaseNativeAudio()
        attemptedStream = nil; nativeActive = false; current = video; inlinePlayerVisible = true
        fullScreen = false; muted = false; player.isMuted = false
        captionTracks = []; selectedCaptionID = ""; preferredCaptionID = ""; captionsLoaded = false; nativeCaptionGroup = nil
        player.defaultRate = Float(playbackSpeed)
        nativePictureInPicture = false; webPictureInPicture = false
        elapsed = 0; duration = 0; playerMessage = "Loading video…"
        playbackRequested = true
        startingPlayback = true
        history.removeAll { $0.id == video.id }; history.insert(video, at: 0); history = Array(history.prefix(100)); persist(history, "history")
        if let file = offlinePlaybackURL(video.id) {
            nativeActive = true; playerMessage = "Downloaded · available offline"
            activateAudio()
            playerWeb.loadHTMLString("", baseURL: nil)
            let item = AVPlayerItem(url: file)
            player.replaceCurrentItem(with: item); player.play()
            loadNativeCaptions(item)
            return
        }
        playerWeb.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(video.id)&autoplay=1&playsinline=1")!))
    }
    func activateAudio() {
        guard nativeActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try AVAudioSession.sharedInstance().setActive(true)
            ownsNativeAudioSession = true
        }
        catch { playerMessage = "Audio session unavailable: \(error.localizedDescription)" }
    }
    private func releaseNativeAudio() {
        guard ownsNativeAudioSession else { return }
        ownsNativeAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func resume() {
        tracePlayback("resume")
        guard current != nil else { return }
        playbackRequested = true
        startingPlayback = true
        if nativeActive { activateAudio(); player.play() } else { playerWeb.evaluateJavaScript("window.BetterYouTube?.play()", completionHandler: nil) }
    }
    func pause(reason: String = "user") {
        tracePlayback("pause", ["reason": reason])
        playbackRequested = false
        startingPlayback = false
        player.pause(); playerWeb.evaluateJavaScript("window.BetterYouTube?.pause()", completionHandler: nil)
        playing = false; updateNowPlaying()
    }
    func togglePlay() { playing || startingPlayback ? pause() : resume() }
    func toggleMuted() {
        muted.toggle(); player.isMuted = muted
        playerWeb.evaluateJavaScript("window.BetterYouTube?.setMuted(\(muted))", completionHandler: nil)
    }
    func setPlaybackSpeed(_ speed: Double) {
        guard Self.playbackSpeeds.contains(speed) else { return }
        playbackSpeed = speed
        UserDefaults.standard.set(speed, forKey: "playbackSpeed")
        player.defaultRate = Float(speed)
        if nativeActive && player.rate > 0 { player.rate = Float(speed) }
        if !nativeActive { syncPlaybackOptions() }
        tracePlayback("setSpeed", ["rate": speed])
    }
    func selectCaptions(_ track: CaptionTrack?) {
        captionsEnabled = track != nil; preferredCaptionID = track?.id ?? ""
        if let track { captionLanguage = track.language }
        UserDefaults.standard.set(captionsEnabled, forKey: "captionsEnabled")
        UserDefaults.standard.set(captionLanguage, forKey: "captionLanguage")
        if nativeActive { applyNativeCaptions() } else { syncPlaybackOptions() }
        tracePlayback("setCaptions", ["enabled": captionsEnabled, "language": captionLanguage])
    }
    private func syncPlaybackOptions() {
        let options: [String: Any] = ["rate": playbackSpeed, "captions": captionsEnabled, "language": captionLanguage, "captionID": preferredCaptionID]
        guard let data = try? JSONSerialization.data(withJSONObject: options), let json = String(data: data, encoding: .utf8) else { return }
        playerWeb.evaluateJavaScript("window.BetterYouTube?.setOptions(\(json))", completionHandler: nil)
    }
    private func loadNativeCaptions(_ item: AVPlayerItem) {
        captionTracks = []; selectedCaptionID = ""; captionsLoaded = false; nativeCaptionGroup = nil
        Task {
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard player.currentItem === item, nativeActive else { return }
            nativeCaptionGroup = group
            captionTracks = (group?.options ?? []).enumerated().map { index, option in
                CaptionTrack(id: String(index), language: option.extendedLanguageTag ?? option.locale?.identifier ?? "", name: option.displayName)
            }
            captionsLoaded = true; applyNativeCaptions()
        }
    }
    private func applyNativeCaptions() {
        guard let group = nativeCaptionGroup, let item = player.currentItem else { return }
        let track = captionsEnabled ? (captionTracks.first { $0.id == preferredCaptionID } ?? captionTracks.first { $0.language == captionLanguage } ?? captionTracks.first) : nil
        let index = track.flatMap { Int($0.id) }
        item.select(index.map { group.options[$0] }, in: group)
        readNativeCaptionSelection()
    }
    private func readNativeCaptionSelection() {
        guard let group = nativeCaptionGroup, let item = player.currentItem else { return }
        let selection = item.currentMediaSelection.selectedMediaOption(in: group)
        selectedCaptionID = group.options.firstIndex { $0 === selection }.map(String.init) ?? ""
    }
    func toggleFullScreen() {
        guard current != nil, inlinePlayerVisible else { return }
        fullScreen.toggle()
        tracePlayback("fullScreen", ["active": fullScreen])
    }

    private func syncWebPlaybackRequest() {
        guard let current, Self.videoID(playerWeb.url ?? URL(string: "about:blank")!) == current.id else { return }
        tracePlayback("syncWebIntent")
        syncPlaybackOptions()
        playerWeb.evaluateJavaScript("window.BetterYouTube?.setMuted(\(muted)); window.BetterYouTube?.setPlaybackRequested(\(playbackRequested && !nativeActive))", completionHandler: nil)
    }
    func seek(by seconds: Double) {
        if nativeActive { player.seek(to: CMTime(seconds: max(0, elapsed + seconds), preferredTimescale: 600)) }
        else { playerWeb.evaluateJavaScript("window.BetterYouTube?.seek(\(seconds))", completionHandler: nil) }
    }
    func seek(to seconds: Double) {
        if nativeActive { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        else { playerWeb.evaluateJavaScript("window.BetterYouTube?.seekTo(\(seconds))", completionHandler: nil) }
    }
    func closePlayer() {
        fullScreen = false
        pause(); current = nil; nativeActive = false; inlinePlayerVisible = false
        nativePictureInPicture = false; webPictureInPicture = false
        streamTimeout?.cancel(); statusObservation = nil
        player.replaceCurrentItem(with: nil); playerWeb.loadHTMLString("", baseURL: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        releaseNativeAudio()
    }
    func dismissInlinePlayer() {
        fullScreen = false
        inlinePlayerVisible = false
        if !nativePictureInPicture && !webPictureInPicture { closePlayer() }
    }
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { nativePictureInPicture = true }
    func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
        nativePictureInPicture = false
        if !inlinePlayerVisible { closePlayer() }
    }
    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        nativePictureInPicture = false
        if !inlinePlayerVisible { closePlayer() }
    }
    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        inlinePlayerVisible = current != nil
        completionHandler(inlinePlayerVisible)
    }
    func pictureInPicture() {
        playerWeb.evaluateJavaScript("window.BetterYouTube?.pip()") { [weak self] result, _ in
            if result as? Bool != true { self?.playerMessage = "Start the video, then try Picture in Picture again. Some videos don’t support it." }
        }
    }
    func clearHistory() { history = []; persist(history, "history") }

    private func useStream(_ url: URL) {
        guard attemptedStream == nil, current != nil else { return }
        let host = url.host?.lowercased() ?? ""
        guard url.scheme == "https", host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else { return }
        attemptedStream = url.absoluteString
        let videoID = current?.id
        Task {
            let agent = (try? await playerWeb.evaluateJavaScript("navigator.userAgent")) as? String ?? ""
            let cookies = await playerWeb.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard current?.id == videoID, attemptedStream == url.absoluteString else { return }
            prepareNativeStream(url, userAgent: agent, cookies: cookies)
        }
    }
    private func prepareNativeStream(_ url: URL, userAgent: String, cookies: [HTTPCookie]) {
        tracePlayback("prepareNativeStream")
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: userAgent, AVURLAssetHTTPCookiesKey: cookies])
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.tracePlayback("nativeItem", ["status": item.status.rawValue])
                if item.status == .readyToPlay && !self.nativeActive {
                    self.streamTimeout?.cancel()
                    let time = self.elapsed
                    self.nativeActive = true; self.playing = false
                    self.loadNativeCaptions(item)
                    self.startingPlayback = self.playbackRequested; self.playerMessage = nil
                    // Finish stopping WebKit before starting AVPlayer. Otherwise
                    // the delayed web pause can interrupt the new audio session.
                    _ = try? await self.playerWeb.evaluateJavaScript("window.BetterYouTube?.pause()")
                    guard self.player.currentItem === item, self.nativeActive else { return }
                    await self.player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                    guard self.player.currentItem === item, self.nativeActive else { return }
                    if self.playbackRequested { self.activateAudio(); self.player.play() }
                    self.tracePlayback("handoffComplete")
                } else if item.status == .failed {
                    let error = item.error as NSError?
                    NSLog("BetterYouTube native stream failure: %@ %ld", error?.domain ?? "unknown", error?.code ?? 0)
                    self.fallbackToWeb()
                }
            }
        }
        streamTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled, let self, !self.nativeActive else { return }
            self.statusObservation = nil; self.player.replaceCurrentItem(with: nil)
        }
    }
    private func fallbackToWeb() {
        let wasNative = nativeActive
        statusObservation = nil; nativeActive = false; player.replaceCurrentItem(with: nil)
        releaseNativeAudio()
        syncPlaybackOptions()
        if wasNative { seek(to: elapsed); if playbackRequested { resume() } }
        playerMessage = "Using the web player for this video. Try Picture in Picture for background playback."
    }

    private func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.channel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? playbackSpeed : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
    }
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
            let target = command.addTarget { [weak self] _ in
                guard self != nil else { return .noSuchContent }
                Task { @MainActor in action() }; return .success
            }
            remoteTargets.append((command, target))
        }
        add(center.playCommand) { [weak self] in self?.resume() }
        add(center.pauseCommand) { [weak self] in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in self?.togglePlay() }
        center.skipForwardCommand.preferredIntervals = [15]; center.skipBackwardCommand.preferredIntervals = [15]
        add(center.skipForwardCommand) { [weak self] in self?.seek(by: 15) }
        add(center.skipBackwardCommand) { [weak self] in self?.seek(by: -15) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let host = message.frameInfo.securityOrigin.host.lowercased()
        guard message.frameInfo.isMainFrame, host == "youtube.com" || host.hasSuffix(".youtube.com"), let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "feed", message.webView === feedWeb, let cards = body["cards"], let data = try? JSONSerialization.data(withJSONObject: cards), let decoded = try? JSONDecoder().decode([Video].self, from: data) {
            guard tab == .home, !showBrowser, !subscriptionFeed, body["url"] as? String == feedWeb.url?.absoluteString else { return }
            signedOut = body["loggedOut"] as? Bool ?? signedOut
            videos = decoded
            if decoded.isEmpty && body["emptyHome"] as? Bool == true { loadDiscovery(); return }
            if !decoded.isEmpty { loading = false; self.message = nil; feedTimeout?.cancel() }
        }
        guard message.webView === playerWeb else { return }
        if type == "diagnostic" {
            let allowed = ["name", "paused", "muted", "ready", "network", "time", "pending", "wants", "errorName", "presentation", "eventTrusted"]
            tracePlayback("webEvent", body.filter { allowed.contains($0.key) })
        }
        if type == "playback" { tracePlayback("webState", body.filter { ["playing", "starting", "time", "muted", "rate", "captionID", "captionVisible", "captionTracks"].contains($0.key) }) }
        if type == "playerReady", body["videoID"] as? String == current?.id { syncWebPlaybackRequest() }
        if type == "playbackIntent", body["videoID"] as? String == current?.id, !nativeActive, body["requested"] as? Bool == false {
            playbackRequested = false; startingPlayback = false
        }
        if type == "pip", body["videoID"] as? String == current?.id {
            let wasActive = webPictureInPicture
            webPictureInPicture = body["active"] as? Bool ?? false
            if wasActive && !webPictureInPicture && !inlinePlayerVisible { closePlayer() }
        }
        if type == "ads" { adsSkipped += 1 }
        if type == "stream", body["videoID"] as? String == current?.id, let string = body["url"] as? String, let url = URL(string: string) { useStream(url) }
        if type == "playback", body["videoID"] as? String == current?.id, !nativeActive {
            if let tracks = body["captionTracks"], let data = try? JSONSerialization.data(withJSONObject: tracks), let decoded = try? JSONDecoder().decode([CaptionTrack].self, from: data) { captionTracks = decoded }
            selectedCaptionID = body["captionID"] as? String ?? ""
            captionsLoaded = body["captionsLoaded"] as? Bool ?? false
            playing = body["playing"] as? Bool ?? false
            #if targetEnvironment(simulator)
            if playing, ProcessInfo.processInfo.arguments.contains("--simulate-host-audio-interruption"), simulatedInterruptionVideo != current?.id {
                simulatedInterruptionVideo = current?.id
                tracePlayback("simulateHostInterruption")
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            }
            #endif
            startingPlayback = !playing && playbackRequested && body["starting"] as? Bool == true
            elapsed = body["time"] as? Double ?? 0; duration = body["duration"] as? Double ?? 0
            if let title = body["title"] as? String, !title.isEmpty { current?.title = title }
            if playing && playerMessage == "Loading video…" { playerMessage = nil }
            if let current, let index = history.firstIndex(where: { $0.id == current.id }), history[index].title != current.title { history[index] = current; persist(history, "history") }
            updateNowPlaying()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if webView === feedWeb, navigationAction.navigationType == .linkActivated, let id = Self.videoID(url) {
            play(videos.first(where: { $0.id == id }) ?? Video(id: id, title: "YouTube video")); decisionHandler(.cancel); return
        }
        if url.scheme == "about" { decisionHandler(.allow); return }
        guard url.scheme == "https" || url.scheme == "http" else { decisionHandler(.cancel); return }
        let host = url.host?.lowercased() ?? ""
        let internalHost = ["youtube.com", "google.com", "googleusercontent.com", "gstatic.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        if navigationAction.targetFrame?.isMainFrame != false && !internalHost {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated { UIApplication.shared.open(url) }
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https" { webView.load(URLRequest(url: url)) }
        return nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === playerWeb { syncWebPlaybackRequest() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === feedWeb { webView.evaluateJavaScript("window.BetterYouTube?.collect()", completionHandler: nil) }
        else { syncWebPlaybackRequest() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ web: WKWebView, _ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if web === feedWeb {
            guard tab == .home, !subscriptionFeed else { return }
            loading = false; message = "Couldn’t reach YouTube. \(error.localizedDescription)"
        }
        else { startingPlayback = false; playerMessage = "Couldn’t load this video. \(error.localizedDescription)" }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === feedWeb { refresh() } else if current != nil && !nativeActive { playerMessage = "The player was interrupted. Reloading…"; webView.reload() }
    }
}

@MainActor private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: YouTubeEngine?
    init(_ owner: YouTubeEngine) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.userContentController(userContentController, didReceive: message) }
}

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct NativePlayer: UIViewControllerRepresentable {
    let engine: YouTubeEngine
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = engine.player
        controller.delegate = engine
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = engine.player }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = .white; view.prioritizesVideoDevices = true; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
