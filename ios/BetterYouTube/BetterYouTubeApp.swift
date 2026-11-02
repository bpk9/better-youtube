import SwiftUI

let canvas = Color(red: 0.035, green: 0.043, blue: 0.055)
let panel = Color(red: 0.075, green: 0.086, blue: 0.105)
let accent = Color(red: 1, green: 0.29, blue: 0.22)

@main struct BetterYouTubeApp: App {
    @UIApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = YouTubeEngine()
    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine).preferredColorScheme(.dark).tint(accent)
                .onOpenURL { engine.open($0) }
                .onChange(of: scenePhase) { _, phase in
                    OfflineLibrary.shared.foreground(phase == .active)
                    engine.tracePlayback("scenePhase", ["active": phase == .active, "background": phase == .background])
                    engine.updateIdleTimer()
                }
                .task { OfflineLibrary.shared.foreground(true) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: YouTubeEngine
    @State private var search = ""
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var librarySegment = 0
    @ObservedObject private var offline = OfflineLibrary.shared
    @ObservedObject private var account = YouTubeAccount.shared
    @State private var showAccount = false
    @State private var showDownloads = false
    @FocusState private var searchFocused: Bool
    private var showingVideoDetail: Bool { engine.current != nil && engine.inlinePlayerVisible }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !engine.fullScreen { header }
                if showSearch && !engine.fullScreen { searchBar }
                playerArea(size: geometry.size)
                ZStack {
                    WebSurface(webView: engine.feedWeb)
                        .opacity(engine.showBrowser ? 1 : 0.01)
                        .allowsHitTesting(engine.showBrowser && !engine.fullScreen)
                        .accessibilityHidden(!engine.showBrowser || engine.fullScreen)
                    if !engine.showBrowser { nativeFeed.background(canvas) }
                }.frame(maxHeight: engine.fullScreen ? 0 : .infinity).clipped()
                    .accessibilityElement(children: .contain).accessibilityHidden(engine.fullScreen)
                if engine.showBrowser && !engine.fullScreen { browserBar }
                if !engine.fullScreen { tabBar }
            }
        }
        .ignoresSafeArea(.container, edges: engine.fullScreen ? .all : [])
        .statusBarHidden(engine.fullScreen)
        .persistentSystemOverlays(engine.fullScreen ? .hidden : .automatic)
        .background(engine.fullScreen ? Color.black : canvas)
        .sheet(isPresented: $showSettings) { settings }
        .sheet(isPresented: $showAccount) { accountSheet }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .onChange(of: engine.fullScreen) { _, _ in searchFocused = false }
        .onChange(of: engine.tab) { _, _ in searchFocused = false }
        .onChange(of: account.subscriptions.map(\.id)) { _, _ in
            if engine.tab == .subscriptions { engine.selectTab(.subscriptions) }
        }
        .onChange(of: account.signedIn) { _, _ in
            if engine.tab == .subscriptions { engine.selectTab(.subscriptions) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showingVideoDetail {
                Button { engine.dismissInlinePlayer() } label: {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 35, height: 44)
                }.accessibilityLabel("Back").accessibilityIdentifier("backToFeed")
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(accent.gradient).frame(width: 35, height: 35)
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .black)).foregroundStyle(.white).offset(x: 1)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Better YouTube").font(.system(size: 19, weight: .bold, design: .rounded))
                Text("YOUR TIME. YOUR FEED.").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1.8).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { withAnimation { showSearch.toggle(); searchFocused = showSearch } } label: { Image(systemName: "magnifyingglass").frame(width: 34, height: 40) }.accessibilityLabel("Search")
            Button { showAccount = true } label: { Image(systemName: account.signedIn ? "person.crop.circle.fill" : "person.crop.circle").frame(width: 30, height: 40) }.accessibilityLabel("YouTube account")
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 34, height: 40) }.accessibilityLabel("Settings")
        }
        .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search or paste a YouTube link", text: $search)
                .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($searchFocused).accessibilityIdentifier("searchField")
                .onSubmit { performSearch() }
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search") }
            Button(action: performSearch) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.accessibilityLabel("Submit search")
        }
        .padding(12).background(panel, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 18).padding(.bottom, 12)
    }
    private func performSearch() { searchFocused = false; engine.search(search) }

    private var nativeFeed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if engine.tab == .library {
                    if !showingVideoDetail {
                        sectionHeading("Your library", subtitle: "Ready for wherever you watch.")
                        Picker("Collection", selection: $librarySegment) {
                            Text("Downloads").tag(0)
                            Text("History").tag(1)
                        }.pickerStyle(.segmented)
                    }
                    if librarySegment == 0 {
                        DownloadLibraryView(engine: engine, openSettings: { showDownloads = true })
                    } else {
                        if engine.history.isEmpty {
                            emptyState(icon: "clock", title: "Pick up where you left off", text: "Videos you open will appear here, saved only on this iPhone.")
                        }
                        videoList(engine.history)
                    }
                } else if showingVideoDetail {
                    if let video = engine.current, let id = video.channelID {
                        HStack { Text(video.channel).font(.headline); Spacer(); subscriptionButton(ChannelRule(id: id, title: video.channel)) }
                    }
                    videoList(engine.videos)
                } else if engine.tab == .subscriptions && !account.signedIn {
                    sectionHeading("Your subscriptions", subtitle: "Your channels will appear here after you sign in.")
                    emptyState(icon: "person.crop.circle", title: "Please sign in", text: "Connect your Google account to see the channels you subscribe to on YouTube.")
                        .accessibilityIdentifier("followingSignInState")
                    Button("Sign in") { showAccount = true }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("followingSignIn")
                } else {
                    sectionHeading(engine.query.isEmpty ? (engine.subscriptionFeed ? "Latest from your channels" : engine.discoveryMode ? "Explore" : engine.tab == .home ? "Made for your curiosity" : "Your subscriptions") : "Search results", subtitle: engine.query.isEmpty ? (engine.discoveryMode && !engine.subscriptionFeed ? "Discovery picks while your personal feed gets started." : "Find something worth your time.") : "“\(engine.query)”")
                    if !account.signedIn && engine.signedOut && engine.query.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text("Bring your YouTube along").font(.subheadline.bold()); Text("Connect your account for subscriptions.").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Sign in") { showAccount = true }.buttonStyle(.borderedProminent).font(.subheadline.bold())
                        }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if engine.tab == .home { topics }
                    if engine.loading && engine.videos.isEmpty { loadingCards }
                    else if engine.videos.isEmpty {
                        emptyState(icon: engine.tab == .subscriptions ? "person.crop.circle" : "sparkle.magnifyingglass", title: engine.tab == .subscriptions ? "No recent videos" : "Start with something you love", text: engine.message ?? "Search for a video or sign in to YouTube for your personal recommendations.")
                        HStack {
                            Button("Search videos") { showSearch = true; searchFocused = true }.buttonStyle(.borderedProminent)
                            if !account.signedIn { Button("Sign in") { showAccount = true }.buttonStyle(.bordered) }
                        }.font(.subheadline)
                    }
                    videoList(engine.videos)
                    if !engine.videos.isEmpty && !engine.subscriptionFeed {
                        Button { engine.loadMore() } label: { Label("Load more videos", systemImage: "arrow.down").frame(maxWidth: .infinity) }.buttonStyle(.bordered).padding(.top, 5)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .refreshable { if engine.tab == .library { await offline.sync() } else { engine.refresh() } }
        .scrollDismissesKeyboard(.interactively)
    }

    private func startDownload(_ video: Video) {
        offline.download(video)
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 27, weight: .bold, design: .rounded)).tracking(-0.7)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var topics: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["For you", "Music", "Technology", "Science", "Podcasts", "Cooking"], id: \.self) { topic in
                    Button { if topic == "For you" { engine.loadHome() } else { search = topic; engine.search(topic) } } label: {
                        Text(topic).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 10)
                            .background((topic == "For you" && engine.query.isEmpty) || engine.query == topic ? Color.white : panel, in: Capsule())
                            .foregroundStyle((topic == "For you" && engine.query.isEmpty) || engine.query == topic ? canvas : .white)
                    }
                }
            }
        }.contentMargins(.trailing, 2)
    }
    private func videoList(_ items: [Video]) -> some View {
        LazyVStack(spacing: 24) {
            ForEach(items) { video in
                VStack(alignment: .leading, spacing: 12) {
                    Button { engine.play(video) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Thumbnail(video: video).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 17))
                            if !video.duration.isEmpty { Text(video.duration).font(.system(size: 11, weight: .semibold, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 4).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5)).padding(9) }
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Play \(video.title)").accessibilityIdentifier("video-\(video.id)")
                    HStack(alignment: .top, spacing: 12) {
                        ZStack { Circle().fill(panel).frame(width: 34, height: 34); Text(String((video.channel.isEmpty ? "Y" : video.channel).prefix(1))).font(.subheadline.bold()).foregroundStyle(accent) }
                        Button { engine.play(video) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(video.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).foregroundStyle(.white)
                                if !video.channel.isEmpty { Text(video.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                if !video.detail.isEmpty { Text(video.displayDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Menu {
                            Button { startDownload(video) } label: { Label(offline.localURL(video.id) == nil ? "Download for offline" : "Downloaded", systemImage: "arrow.down.circle") }
                            if let channelID = video.channelID {
                                subscriptionButton(ChannelRule(id: channelID, title: video.channel))
                                Button { Task { await offline.setRule(ChannelRule(id: channelID, title: video.channel, enabled: true)) }; showDownloads = true } label: { Label("Auto-download this channel", systemImage: "arrow.triangle.2.circlepath") }
                            }
                            ShareLink(item: video.url)
                        } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 20, height: 30).foregroundStyle(.secondary) }.accessibilityLabel("Video options")
                    }
                }
            }
        }
    }
    private func subscriptionButton(_ channel: ChannelRule) -> some View {
        ChannelSubscriptionButton(channel: channel)
    }

    private var loadingCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 17).fill(panel).aspectRatio(16 / 9, contentMode: .fit).overlay { ProgressView().tint(accent) }
            Text("Finding your next watch…").font(.subheadline).foregroundStyle(.secondary)
        }.accessibilityIdentifier("feedLoading")
    }
    private func emptyState(icon: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(accent).padding(.bottom, 8)
            Text(title).font(.title3.bold())
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).background(panel, in: RoundedRectangle(cornerRadius: 22))
    }

    private func playerArea(size: CGSize) -> some View {
        VStack(spacing: 0) {
            ZStack {
                WebSurface(webView: engine.playerWeb).opacity(engine.nativeActive ? 0.01 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if engine.nativeActive {
                    NativePlayer(engine: engine).accessibilityIdentifier("nativeVideoSurface")
                    VStack { HStack { Spacer(); PlaybackSettingsMenu(engine: engine).equatable(); FullScreenButton(engine: engine) }; Spacer() }.padding(16)
                }
                else if engine.current != nil && engine.inlinePlayerVisible { WebVideoControls(engine: engine) }
            }
            .frame(height: engine.current != nil && engine.inlinePlayerVisible ? (engine.fullScreen ? size.height : min(size.width * 9 / 16, 260)) : 0)
            .clipped()
            if let video = engine.current, engine.inlinePlayerVisible, !engine.fullScreen {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Menu {
                                Button { startDownload(video) } label: { Label("Download current video", systemImage: "arrow.down.circle") }
                                ShareLink(item: video.url)
                            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 28) }
                                .accessibilityLabel("Video actions").accessibilityIdentifier("videoActions")
                        }
                        HStack {
                            Circle().fill(engine.playing ? Color.green : Color.secondary).frame(width: 5, height: 5)
                            Text(engine.playing ? "Playing" : engine.startingPlayback ? "Loading" : "Paused").accessibilityIdentifier("playbackStatus")
                            Spacer()
                            Text("\(time(engine.elapsed)) / \(time(engine.duration))").monospacedDigit().accessibilityIdentifier("playbackTime")
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                        if let record = offline.record(video.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    if !["ready", "failed", "expired"].contains(record.state) { ProgressView().controlSize(.small) }
                                    Text(record.statusText).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("View downloads") { librarySegment = 0; engine.tapTab(.library) }.font(.caption.weight(.semibold))
                                }
                                if record.state == "downloading" { ProgressView(value: record.progress).tint(accent) }
                            }
                        }
                        if let message = engine.playerMessage, message != "Loading video…", !message.hasPrefix("Using the web player") { Text(message).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.horizontal, 18).padding(.vertical, 12).background(panel)

            }
        }.foregroundStyle(.white)
    }
    private func time(_ value: Double) -> String { let seconds = Int(max(0, value)); return "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
    private var browserBar: some View {
        HStack {
            Button { engine.feedWeb.goBack() } label: { Image(systemName: "chevron.left").frame(width: 36, height: 35) }.accessibilityLabel("Back")
            Text("YouTube · secure web view").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { engine.finishBrowsing() }.font(.subheadline.bold())
        }.padding(.horizontal, 18).background(panel)
    }
    private var tabBar: some View {
        HStack {
            ForEach(FeedTab.allCases, id: \.self) { tab in
                Button { engine.tapTab(tab) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab == .home ? (engine.tab == tab ? "house.fill" : "house") : tab == .subscriptions ? "play.rectangle.on.rectangle" : (engine.tab == tab ? "square.stack.fill" : "square.stack")).font(.system(size: 20))
                        Text(tab.rawValue).font(.system(size: 10, weight: .medium))
                    }.foregroundStyle(engine.tab == tab ? accent : .secondary).frame(maxWidth: .infinity).frame(height: 52)
                }.accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }.padding(.top, 5).background(canvas.overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5) })
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A calmer way to watch.", systemImage: "play.rectangle.fill").font(.headline)
                    Text("Better YouTube · version 0.12").font(.caption).foregroundStyle(.secondary)
                }
                Section("Your YouTube") {
                    Button { showSettings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showAccount = true } } label: { Label("Sign in / manage account", systemImage: "person.crop.circle") }
                    Button { showSettings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showDownloads = true } } label: { Label("Download settings", systemImage: "arrow.down.circle") }
                }
                Section {
                    Toggle("Block ads", isOn: $engine.blockAds).onChange(of: engine.blockAds) { _, _ in engine.applySettings() }
                    LabeledContent("Filter", value: engine.blockAds ? (engine.blockerReady ? "Loaded" : "Unavailable") : "Off").accessibilityIdentifier("filterStatus")
                    if let error = engine.blockerError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    LabeledContent("Video ads skipped this session", value: String(engine.adsSkipped))
                } header: { Text("Ad blocking") } footer: { Text("Blocks known ad requests and removes ad placements. YouTube changes regularly; some ads or playback interruptions may still occur.") }
                Section {
                    Toggle("Background playback", isOn: $engine.backgroundAudio).onChange(of: engine.backgroundAudio) { _, _ in engine.applySettings() }
                } header: { Text("Keep listening") } footer: { Text("Native playback supports background audio and lock-screen controls. When a video uses the web player, try Picture in Picture before leaving the app. Background playback is experimental and may vary by video.") }
                Section("On this iPhone") {
                    LabeledContent("Downloaded videos", value: String(offline.records.filter { $0.state == "ready" }.count))
                    Button("Clear watch history", role: .destructive) { engine.clearHistory() }
                    Text("History and offline videos stay on this iPhone. Google tokens stay in its Keychain. The companion receives video IDs and channel rules; it does not receive your Google login.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Make it yours").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }.tint(accent)
    }

    private var accountSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Label(account.signedIn ? "YouTube connected" : "Your channels, in one place", systemImage: "person.crop.circle.fill").font(.headline)
                    Text(account.signedIn ? "Connected to Google" : "Not connected to Google").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("accountConnectionStatus")
                    Text("Connect Google to manage your YouTube subscriptions. Choose which channels should download automatically.").font(.subheadline).foregroundStyle(.secondary)
                    if account.signedIn {
                        LabeledContent("Subscriptions", value: String(account.subscriptions.count))
                        Button("Refresh subscriptions") { Task { await account.refreshSubscriptions(); engine.selectTab(.subscriptions) } }
                        Button("Disconnect Google", role: .destructive) { account.signOut() }.disabled(account.updatingSubscriptions || account.busy)
                        if !account.canManageSubscriptions {
                            Text("Reconnect Google to allow subscribing and unsubscribing from channels.").font(.caption).foregroundStyle(.secondary)
                            Button("Allow subscription changes") { account.signIn() }.disabled(account.busy || account.updatingSubscriptions)
                        }
                        if account.updatingSubscriptions || account.busy { ProgressView("Updating…") }
                    } else {
                        Button { account.signIn() } label: { Label("Sign in with Google", systemImage: "person.badge.key.fill") }.disabled(account.busy || !account.configured)
                        if account.busy { ProgressView("Connecting…") }
                        if !account.configured {
                            Text("Sign-in setup is not finished").font(.subheadline.bold()).accessibilityIdentifier("signInSetupRequired")
                            Text("Configure a Google iOS OAuth client for this build to enable sign-in. The button above will then let you choose your Google account.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = account.error { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Section("How sign-in works") {
                    Text("Signing into YouTube in Safari or the YouTube app does not connect Better YouTube. You can keep the YouTube app installed.").font(.subheadline).foregroundStyle(.secondary)
                }
                if !account.subscriptions.isEmpty {
                    Section("Subscriptions") {
                        ForEach(account.subscriptions) { channel in
                            HStack { Text(channel.title); Spacer(); Button { Task { await offline.setRule(ChannelRule(id: channel.id, title: channel.title, enabled: true)) }; showAccount = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showDownloads = true } } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("Auto-download \(channel.title)").buttonStyle(.borderless); subscriptionButton(channel).buttonStyle(.borderless) }
                        }
                    }
                }
            }
            .navigationTitle("YouTube account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAccount = false; if account.signedIn { engine.selectTab(.subscriptions) } } } }
        }
    }
}

// Each button owns its presentation so permission and error alerts work both
// in the feed and inside the already-presented account sheet.
private struct ChannelSubscriptionButton: View {
    let channel: ChannelRule
    @ObservedObject private var account = YouTubeAccount.shared
    @State private var notice: Notice?
    @State private var requestedSubscription = false
    @State private var awaitingAuthorization = false

    private enum Notice: Identifiable {
        case permission, failure(String)
        var id: String { switch self { case .permission: return "permission"; case .failure: return "failure" } }
    }

    var body: some View {
        let subscribed = account.isSubscribed(to: channel.id)
        Button {
            requestedSubscription = !subscribed
            if !account.signedIn || !account.canManageSubscriptions {
                notice = .permission
            } else {
                Task { await changeSubscription() }
            }
        } label: {
            Label(subscribed ? "Unsubscribe" : "Subscribe", systemImage: subscribed ? "person.badge.minus" : "person.badge.plus")
        }
        .disabled(account.updatingSubscriptions || account.busy)
        .accessibilityLabel("\(subscribed ? "Unsubscribe from" : "Subscribe to") \(channel.title)")
        .alert(item: $notice) { item in
            switch item {
            case .permission:
                return Alert(
                    title: Text("Allow subscription changes"),
                    message: Text("Reconnect Google to \(requestedSubscription ? "subscribe to" : "unsubscribe from") \(channel.title). Your current connection can only read subscriptions. After you grant access, we’ll finish this change."),
                    primaryButton: .default(Text("Connect Google")) {
                        awaitingAuthorization = true
                        account.signIn { await changeSubscription() }
                    },
                    secondaryButton: .cancel()
                )
            case .failure(let message):
                return Alert(title: Text("Subscription wasn’t changed"), message: Text(message), dismissButton: .default(Text("OK")))
            }
        }
        .onChange(of: account.busy) { _, busy in
            if !busy && awaitingAuthorization {
                awaitingAuthorization = false
                if let error = account.error { notice = .failure(error) }
            }
        }
        .onChange(of: account.error) { _, error in
            if awaitingAuthorization, let error { notice = .failure(error) }
        }
    }

    @MainActor private func changeSubscription() async {
        await account.setSubscribed(requestedSubscription, channel: channel)
        if let error = account.error { notice = .failure(error) }
    }
}

// Video-surface taps reveal controls; only the explicit transport buttons change
// playback. YouTube's mobile page otherwise treats the same tap as play/pause.
private struct WebVideoControls: View {
    @ObservedObject var engine: YouTubeEngine
    @State private var visible = false
    var body: some View {
        ZStack {
            Button {
                visible.toggle()
                engine.tracePlayback("videoControls", ["visible": visible])
            } label: {
                Rectangle().fill(visible ? Color.black.opacity(0.35) : Color.clear).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(visible ? "Hide video controls" : "Show video controls")
            .accessibilityIdentifier("videoSurface")
            if visible {
                VStack {
                    HStack(spacing: 12) {
                        Button { engine.toggleMuted() } label: { Image(systemName: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel(engine.muted ? "Unmute video" : "Mute video")
                        Spacer()
                        PlaybackSettingsMenu(engine: engine).equatable()
                        Button { engine.pictureInPicture() } label: { Image(systemName: "pip.enter").frame(width: 44, height: 44) }.accessibilityLabel("Picture in Picture")
                        AirPlayButton().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
                        FullScreenButton(engine: engine)
                    }.font(.title3).foregroundStyle(.white)
                    Spacer()
                    PlaybackScrubber(engine: engine)
                    if engine.fullScreen {
                        Text("\(Int(engine.elapsed) / 60):\(String(format: "%02d", Int(engine.elapsed) % 60))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white).accessibilityIdentifier("fullscreenTime")
                    }
                }.padding(.horizontal, 12).padding(.vertical, engine.fullScreen ? 40 : 4)
                HStack(spacing: 44) {
                    Button { engine.seek(by: -15) } label: { Image(systemName: "gobackward.15") }
                        .accessibilityLabel("Back 15 seconds in video")
                    Button { engine.togglePlay() } label: {
                        Image(systemName: engine.playing || engine.startingPlayback ? "pause.fill" : "play.fill")
                    }.accessibilityLabel(engine.playing || engine.startingPlayback ? "Pause in video" : "Play in video")
                        .accessibilityIdentifier("videoOverlayPlayPause")
                    Button { engine.seek(by: 15) } label: { Image(systemName: "goforward.15") }
                        .accessibilityLabel("Forward 15 seconds in video")
                }.font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    .buttonStyle(.plain)
            }
        }.onChange(of: engine.current?.id) { _, _ in visible = false }
    }
}

private struct PlaybackScrubber: View {
    @ObservedObject var engine: YouTubeEngine
    @State private var scrubbing = false
    @State private var position = 0.0
    @State private var pendingSeek: Double?

    private var duration: Double { engine.duration.isFinite ? max(0, engine.duration) : 0 }
    private var displayedPosition: Double {
        let value = scrubbing ? position : (pendingSeek ?? engine.elapsed)
        return value.isFinite ? min(max(0, value), duration) : 0
    }

    var body: some View {
        Slider(value: Binding(
            get: { displayedPosition },
            set: { value in
                position = value
                // Accessibility adjustments commit without a drag gesture.
                if !scrubbing { commitSeek(value) }
            }
        ), in: 0...max(duration, 1), onEditingChanged: { editing in
            if editing { position = displayedPosition; pendingSeek = nil }
            scrubbing = editing
            if !editing { commitSeek(position) }
        })
        .tint(.white)
        .disabled(duration <= 0)
        .accessibilityLabel("Video progress")
        .accessibilityIdentifier("videoScrubber")
        .accessibilityValue("\(timestamp(displayedPosition)) of \(timestamp(duration))")
        .frame(minHeight: 44)
        .onChange(of: engine.elapsed) { _, elapsed in
            // Keep the released thumb in place while old progress reports arrive.
            if let target = pendingSeek, abs(elapsed - target) < 2 { pendingSeek = nil }
        }
        .task(id: pendingSeek) {
            guard pendingSeek != nil else { return }
            // Recover if the player rejects the seek or stops reporting progress.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            pendingSeek = nil
        }
        .onChange(of: engine.current?.id) { _, _ in scrubbing = false; position = 0; pendingSeek = nil }
    }

    private func commitSeek(_ value: Double) {
        let target = min(max(0, value), duration)
        pendingSeek = target
        engine.seek(to: target)
    }

    private func timestamp(_ value: Double) -> String {
        let seconds = Int(value)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct FullScreenButton: View {
    @ObservedObject var engine: YouTubeEngine
    var body: some View {
        Button { engine.toggleFullScreen() } label: {
            Image(systemName: engine.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.title3).foregroundStyle(.white).frame(width: 44, height: 44)
                .background(.black.opacity(0.25), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(engine.fullScreen ? "Exit full screen" : "Full screen")
            .accessibilityIdentifier("toggleFullScreen")
    }
}

private struct PlaybackSettingsMenu: View, Equatable {
    let engine: YouTubeEngine
    let speed: Double
    let tracks: [CaptionTrack]
    let selectedID: String
    let loaded: Bool
    init(engine: YouTubeEngine) {
        self.engine = engine; speed = engine.playbackSpeed; tracks = engine.captionTracks
        selectedID = engine.selectedCaptionID; loaded = engine.captionsLoaded
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine === rhs.engine && lhs.speed == rhs.speed && lhs.tracks == rhs.tracks && lhs.selectedID == rhs.selectedID && lhs.loaded == rhs.loaded
    }
    private var captionSummary: String { tracks.first { $0.id == selectedID }?.name ?? "Off" }
    var body: some View {
        Menu {
            Menu {
                ForEach(YouTubeEngine.playbackSpeeds, id: \.self) { speed in
                    Button { engine.setPlaybackSpeed(speed) } label: {
                        if self.speed == speed { Label(speedLabel(speed), systemImage: "checkmark") }
                        else { Text(speedLabel(speed)) }
                    }.accessibilityIdentifier("speed-\(speed)")
                }
            } label: { Label("Playback speed · \(speedLabel(speed))", systemImage: "speedometer") }
                .accessibilityIdentifier("playbackSpeedMenu")
            Menu {
                Button { engine.selectCaptions(nil) } label: {
                    if selectedID.isEmpty { Label("Off", systemImage: "checkmark") }
                    else { Text("Off") }
                }.accessibilityIdentifier("captionsOff")
                ForEach(tracks) { track in
                    Button { engine.selectCaptions(track) } label: {
                        if selectedID == track.id { Label(track.name, systemImage: "checkmark") }
                        else { Text(track.name) }
                    }.accessibilityIdentifier("caption-\(track.id)")
                }
                if tracks.isEmpty {
                    Text(loaded ? "No captions available for this video" : "Checking available captions…")
                }
            } label: { Label("Captions · \(captionSummary)", systemImage: "captions.bubble") }
                .accessibilityIdentifier("captionsMenu")
        } label: {
            Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.white).frame(width: 44, height: 44)
                .background(.black.opacity(0.25), in: Circle())
        }.accessibilityLabel("Playback settings").accessibilityIdentifier("playbackSettings")
            .accessibilityValue("\(speedLabel(speed)), Captions \(captionSummary)")
    }
    private func speedLabel(_ speed: Double) -> String { speed == 1 ? "1× (Normal)" : "\(speed.formatted(.number.precision(.fractionLength(0...2))))×" }
}

struct Thumbnail: View {
    let video: Video
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: video.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { panel.overlay { Image(systemName: "play.rectangle").font(.title).foregroundStyle(.white.opacity(0.2)) } }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}
