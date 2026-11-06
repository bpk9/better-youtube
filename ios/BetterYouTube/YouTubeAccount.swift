import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

@MainActor final class YouTubeAccount: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = YouTubeAccount()
    @Published var subscriptions: [ChannelRule] = []
    @Published var busy = false
    @Published var error: String?
    @Published var signedIn = false
    @Published var updatingSubscriptions = false
    @Published var canManageSubscriptions = SecureStore.read("google-scopes")?.components(separatedBy: " ").contains("https://www.googleapis.com/auth/youtube.force-ssl") == true
    private var refreshingSubscriptions = false
    private var accountRevision = 0
    private var session: ASWebAuthenticationSession?
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    var clientID: String? {
        guard let path = Bundle.main.url(forResource: "Connection", withExtension: "plist"), let data = try? Data(contentsOf: path),
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let id = config["GoogleClientID"], id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return id
    }
    var configured: Bool { clientID != nil }
    override init() {
        super.init()
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--following-filter-test") {
            signedIn = true
            subscriptions = (1...45).map { ChannelRule(id: String(format: "UC%022d", $0), title: String(format: "Channel %02d", $0)) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--subscription-permission-test") {
            signedIn = true
            canManageSubscriptions = false
            subscriptions = [ChannelRule(id: "UCabcdefghijklmnopqrstuv", title: "Example Channel")]
            return
        }
        #endif
        signedIn = SecureStore.read("google-refresh") != nil
        if let data = UserDefaults.standard.data(forKey: "googleSubscriptions"), let list = try? JSONDecoder().decode([ChannelRule].self, from: data) { subscriptions = list }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func random() -> String { var data = Data(count: 32); _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }; return base64(data) }
    private func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func signIn(onAuthorized: (() async -> Void)? = nil) {
        guard let clientID else { error = "Google sign-in needs a one-time app registration. The app’s iOS client ID hasn’t been configured yet."; return }
        guard !busy, !updatingSubscriptions else { return }
        let scheme = clientID.components(separatedBy: ".").reversed().joined(separator: ".")
        let redirect = scheme + ":/oauthredirect"
        let state = random(), verifier = random()
        let challenge = base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": "https://www.googleapis.com/auth/youtube.force-ssl", "code_challenge": challenge, "code_challenge_method": "S256", "state": state, "access_type": "offline", "prompt": "consent"].map { URLQueryItem(name: $0.key, value: $0.value) }
        busy = true; error = nil
        session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: scheme) { [weak self] callback, failure in
            Task { @MainActor in
                guard let self else { return }
                defer { self.busy = false; self.session = nil }
                if let failure { if (failure as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue { self.error = failure.localizedDescription }; return }
                guard let callback, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                      items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value else { self.error = "Google didn’t complete sign-in. Please try again."; return }
                do {
                    try await self.exchange(["client_id": clientID, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"])
                    self.signedIn = true
                    await self.refreshSubscriptions()
                    self.busy = false
                    if let onAuthorized { await onAuthorized() }
                } catch { self.error = error.localizedDescription }
            }
        }
        session?.presentationContextProvider = self
        session?.prefersEphemeralWebBrowserSession = false
        if session?.start() != true { busy = false; error = "Couldn’t open Google sign-in." }
    }
    private func exchange(_ fields: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents(); body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = object?["access_token"] as? String else {
            throw NSError(domain: "Google", code: 1, userInfo: [NSLocalizedDescriptionKey: object?["error_description"] as? String ?? "Google authorization failed. Sign in again."])
        }
        // OAuth may omit scope when it exactly matches the authorization request.
        let grantedScope = object?["scope"] as? String ?? (fields["grant_type"] == "authorization_code" ? "https://www.googleapis.com/auth/youtube.force-ssl" : nil)
        if let scope = grantedScope {
            SecureStore.save(scope, key: "google-scopes")
            canManageSubscriptions = scope.components(separatedBy: " ").contains("https://www.googleapis.com/auth/youtube.force-ssl")
        }
        accessToken = token; expiresAt = Date(timeIntervalSinceNow: (object?["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = object?["refresh_token"] as? String { SecureStore.save(refresh, key: "google-refresh") }
    }
    func refreshSubscriptions() async {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--subscription-permission-test") || ProcessInfo.processInfo.arguments.contains("--following-filter-test") { return }
        #endif
        guard let clientID, !refreshingSubscriptions, !updatingSubscriptions else { return }
        refreshingSubscriptions = true
        let revision = accountRevision
        defer { refreshingSubscriptions = false }
        do {
            if accessToken == nil || expiresAt < Date() {
                guard let refresh = SecureStore.read("google-refresh") else { return }
                try await exchange(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
            }
            guard let accessToken else { return }
            var result: [ChannelRule] = [], next: String?
            repeat {
                var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/subscriptions")!
                components.queryItems = [URLQueryItem(name: "part", value: "snippet"), URLQueryItem(name: "mine", value: "true"), URLQueryItem(name: "maxResults", value: "50")]
                if let next { components.queryItems?.append(URLQueryItem(name: "pageToken", value: next)) }
                var request = URLRequest(url: components.url!); request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Google", code: 2, userInfo: [NSLocalizedDescriptionKey: "YouTube could not load subscriptions. Check that YouTube Data API v3 is enabled for the app’s Google project."]) }
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                for item in object["items"] as? [[String: Any]] ?? [] {
                    if let snippet = item["snippet"] as? [String: Any], let resource = snippet["resourceId"] as? [String: Any], let id = resource["channelId"] as? String, let title = snippet["title"] as? String {
                        let thumbnails = snippet["thumbnails"] as? [String: [String: Any]]
                        let thumbnail = thumbnails?["medium"]?["url"] as? String ?? thumbnails?["default"]?["url"] as? String ?? thumbnails?["high"]?["url"] as? String
                        result.append(ChannelRule(id: id, title: title, thumbnailURL: thumbnail))
                    }
                }
                next = object["nextPageToken"] as? String
            } while next != nil
            guard revision == accountRevision else { return }
            subscriptions = result; signedIn = true; error = nil
            UserDefaults.standard.set(try JSONEncoder().encode(result), forKey: "googleSubscriptions")
            if OfflineLibrary.shared.isConfigured { await OfflineLibrary.shared.importChannels(Array(result.prefix(100))) }
        } catch { if revision == accountRevision { self.error = error.localizedDescription } }
    }
    func isSubscribed(to channelID: String) -> Bool {
        subscriptions.contains { $0.id == channelID }
    }

    /// Look up the server subscription before changing it: deletion takes a
    /// subscription resource ID, not the channel ID, and the cache may be stale.
    func setSubscribed(_ subscribed: Bool, channel: ChannelRule) async {
        guard !busy, !updatingSubscriptions else { return }
        guard signedIn, canManageSubscriptions else {
            error = "Google hasn’t granted permission to change subscriptions. Reconnect and allow YouTube access to continue."
            return
        }
        updatingSubscriptions = true
        accountRevision += 1 // Discard any older list request still in flight.
        defer { updatingSubscriptions = false }
        error = nil
        do {
            let existing = try await subscriptionRequest(query: [
                URLQueryItem(name: "part", value: "id"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "forChannelId", value: channel.id)
            ])
            let id = (existing["items"] as? [[String: Any]])?.first?["id"] as? String
            if subscribed && id == nil {
                _ = try await subscriptionRequest(method: "POST", query: [URLQueryItem(name: "part", value: "snippet")], body: [
                    "snippet": ["resourceId": ["kind": "youtube#channel", "channelId": channel.id]]
                ])
            } else if !subscribed, let id {
                _ = try await subscriptionRequest(method: "DELETE", query: [URLQueryItem(name: "id", value: id)])
            }
            subscriptions.removeAll { $0.id == channel.id }
            if subscribed { subscriptions.append(channel) }
            UserDefaults.standard.set(try JSONEncoder().encode(subscriptions), forKey: "googleSubscriptions")
        } catch { self.error = error.localizedDescription }
    }

    private func subscriptionRequest(method: String = "GET", query: [URLQueryItem], body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let clientID, let refresh = SecureStore.read("google-refresh") else {
            throw NSError(domain: "Google", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign in with Google to manage subscriptions."])
        }
        if accessToken == nil || expiresAt < Date() {
            try await exchange(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
        }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/subscriptions")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer " + (accessToken ?? ""), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if method == "DELETE" && status == 404 { return [:] }
        guard (200..<300).contains(status) else {
            let details = object["error"] as? [String: Any]
            let reasons = details?["errors"] as? [[String: Any]] ?? []
            if reasons.contains(where: { $0["reason"] as? String == "insufficientPermissions" }) {
                canManageSubscriptions = false
                SecureStore.remove("google-scopes")
            }
            throw NSError(domain: "YouTube", code: status, userInfo: [NSLocalizedDescriptionKey: details?["message"] as? String ?? "YouTube couldn’t update your subscription. Please try again."])
        }
        return object
    }

    func signOut() {
        guard !updatingSubscriptions, !busy else { return }
        accountRevision += 1
        canManageSubscriptions = false; SecureStore.remove("google-scopes")
        session?.cancel(); accessToken = nil; SecureStore.remove("google-refresh"); signedIn = false; subscriptions = []
        UserDefaults.standard.removeObject(forKey: "googleSubscriptions")
    }
}

struct ChannelVideoFeed {
    static func load(_ channels: [ChannelRule], perChannelLimit: Int = 3) async -> [Video] {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--following-filter-test") {
            // Keep requests in flight so UI tests exercise stale-result protection.
            let delay = channels.count == 1 ? (channels.first?.title == "Channel 01" ? 2000 : 600) : 1200
            try? await Task.sleep(for: .milliseconds(delay))
            return channels.prefix(40).flatMap { channel in
                (1...min(perChannelLimit, 5)).map { index in
                    Video(id: String(channel.id.suffix(9)) + String(format: "%02d", index), title: "\(channel.title) upload \(index)", channel: channel.title, detail: "2026-11-01T12:00:00Z", channelID: channel.id)
                }
            }
        }
        #endif
        return await withTaskGroup(of: [Video].self, returning: [Video].self) { group in
            var iterator = channels.prefix(40).makeIterator()
            func add(_ channel: ChannelRule) {
                group.addTask {
                    do {
                        var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
                        components.queryItems = [URLQueryItem(name: "channel_id", value: channel.id)]
                        var request = URLRequest(url: components.url!); request.timeoutInterval = 15
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { return [] }
                        let reader = ChannelXMLReader(channel: channel)
                        let parser = XMLParser(data: data); parser.delegate = reader; parser.shouldResolveExternalEntities = false
                        return parser.parse() ? Array(reader.videos.prefix(perChannelLimit)) : []
                    } catch { return [] }
                }
            }
            for _ in 0..<4 { if let next = iterator.next() { add(next) } }
            var result: [Video] = []
            for await items in group { result += items; if let next = iterator.next() { add(next) } }
            return result.sorted { $0.detail > $1.detail }
        }
    }
}

private final class ChannelXMLReader: NSObject, XMLParserDelegate {
    let channel: ChannelRule
    var videos: [Video] = []
    private var inside = false, current = "", value = "", id = "", title = "", published = ""
    init(channel: ChannelRule) { self.channel = channel }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "entry" { inside = true; id = ""; title = ""; published = "" }
        current = elementName; value = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inside else { return }
        if elementName == "yt:videoId" { id = value }
        if elementName == "title" { title = value }
        if elementName == "published" { published = value }
        if elementName == "entry" {
            if id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { videos.append(Video(id: id, title: title, channel: channel.title, detail: published, channelID: channel.id)) }
            inside = false
        }
    }
}
