import Foundation

private final class MockHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: (URLRequest) throws -> (Int, Data) = { _ in fatalError("No HTTP handler") }
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            Self.requests.append(request)
            let handler = Self.handler
            Self.lock.unlock()
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func configure(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        lock.lock(); self.handler = handler; requests = []; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: config)
    }
}

@main struct FeedTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "FeedTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func json(_ object: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: object)) }
    static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    static func channelResponse(_ request: URLRequest) throws -> (Int, Data) {
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "API requests must use OAuth headers")
        try check(request.url?.host == "www.googleapis.com", "Signed-in feed must not depend on RSS")
        let ids = query(request, "id")!.components(separatedBy: ",")
        try check(ids.count <= 50, "Channel lookup must batch at 50")
        return try json(["items": ids.map { ["id": $0, "contentDetails": ["relatedPlaylists": ["uploads": "uploads-" + $0]]] }])
    }
    static func upload(_ id: String, date: String = "2026-11-03T12:00:00Z", privacy: String = "public") -> [String: Any] {
        ["snippet": ["title": "Upload " + id, "publishedAt": "2030-01-01T00:00:00Z"],
         "contentDetails": ["videoId": id, "videoPublishedAt": date], "status": ["privacyStatus": privacy]]
    }
    static func main() async throws {
        // More than 40 subscriptions, channel batching, deduplication, and real publication dates.
        let channels = (0..<55).map { ChannelRule(id: "channel-\($0)", title: "Channel \($0)") }
        var session = MockHTTP.configure { request in
            if request.url!.lastPathComponent == "channels" { return try channelResponse(request) }
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Uploads require OAuth")
            try check(query(request, "part") == "snippet,contentDetails,status", "Request upload metadata")
            try check(query(request, "maxResults") == "15", "Load recent uploads beyond the first three")
            let number = Int(query(request, "playlistId")!.split(separator: "-").last!)!
            let date = number == 54 ? "2026-11-03T12:00:00.500Z" : "2026-11-03T12:00:00Z"
            return try json(["items": [upload(String(format: "video%06d", number), date: date)]])
        }
        let all = try await ChannelVideoFeed.load(channels + [channels[0]], accessToken: "test-token", session: session)
        try check(all.videos.count == 55, "Every subscription must be checked, including those after 40")
        try check(all.videos.first?.channelID == "channel-54", "Sort fractional timestamps by publication time")
        try check(all.videos.first?.detail == "2026-11-03T12:00:00.500Z", "Use video publication date, not playlist addition date")
        try check(MockHTTP.requests.count == 57 && all.failedChannels == 0, "Two channel batches plus one request per unique channel")
        print("PASS: all subscriptions, 50-channel batches, OAuth, dates, deduplication")

        session = MockHTTP.configure { request in
            if request.url!.lastPathComponent == "channels" { return try channelResponse(request) }
            return try json(["items": [upload("public00001"), upload("public00001"), upload("private0001", privacy: "private"), upload("bad-id"), ["snippet": ["title": "Deleted video"]]]])
        }
        let filtered = try await ChannelVideoFeed.load([channels[0]], accessToken: "test-token", session: session)
        try check(filtered.videos.map(\.id) == ["public00001"], "Ignore private, deleted, invalid and duplicate videos")
        print("PASS: unavailable videos and duplicate videos")

        session = MockHTTP.configure { request in
            if request.url!.lastPathComponent == "channels" { return try channelResponse(request) }
            if query(request, "playlistId") == "uploads-channel-0" { throw URLError(.notConnectedToInternet) }
            return try json(["items": [upload("public00001")]])
        }
        let partial = try await ChannelVideoFeed.load(Array(channels.prefix(2)), accessToken: "test-token", session: session)
        try check(partial.videos.count == 1 && partial.failedChannels == 1 && partial.message != nil, "A channel failure must not hide successful uploads")
        print("PASS: partial channel failures preserve successful results")

        for (status, reason) in [(403, "quotaExceeded"), (401, "authError")] {
            session = MockHTTP.configure { request in
                if request.url!.lastPathComponent == "channels" { return try channelResponse(request) }
                return (status, try JSONSerialization.data(withJSONObject: ["error": ["message": "Failure", "errors": [["reason": reason]]]]))
            }
            do {
                _ = try await ChannelVideoFeed.load(channels, accessToken: "test-token", session: session)
                throw NSError(domain: "FeedTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "API failures must throw"])
            } catch ChannelVideoFeed.FeedError.api(let code, let actualReason, _) {
                try check(code == status && actualReason == reason, "Preserve authentication and quota failures")
                try check(MockHTTP.requests.count <= 6, "Stop scheduling requests after an account-wide failure")
            }
        }
        print("PASS: authentication and quota errors stop further requests")

        session = MockHTTP.configure { request in
            if request.url!.lastPathComponent == "channels" { return try channelResponse(request) }
            return try json(["items": []])
        }
        let empty = try await ChannelVideoFeed.load([channels[0]], accessToken: "test-token", session: session)
        try check(empty.videos.isEmpty && empty.failedChannels == 0 && empty.message == nil, "An empty channel is not a network failure")

        session = MockHTTP.configure { _ in (200, Data("{broken".utf8)) }
        do {
            _ = try await ChannelVideoFeed.load([channels[0]], accessToken: "test-token", session: session)
            throw NSError(domain: "FeedTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Malformed response must throw"])
        } catch is DecodingError { }
        print("PASS: empty feeds differ from unreadable responses")

        session = MockHTTP.configure { request in
            try check(request.value(forHTTPHeaderField: "Authorization") == nil, "Never send Google tokens to RSS")
            return (200, Data("""
                <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"><entry><yt:videoId>public00001</yt:videoId><title>A &amp; B</title><published>2026-11-03T12:00:00Z</published></entry></feed>
                """.utf8))
        }
        let rss = try await ChannelVideoFeed.load([channels[0]], session: session)
        try check(rss.videos.first?.title == "A & B", "Signed-out RSS discovery still parses correctly")
        session = MockHTTP.configure { _ in (404, Data("Not found".utf8)) }
        do {
            _ = try await ChannelVideoFeed.load([channels[0]], session: session)
            throw NSError(domain: "FeedTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "RSS 404 must not become an empty success"])
        } catch ChannelVideoFeed.FeedError.invalidResponse { }
        print("PASS: RSS discovery and RSS HTTP failures")
    }
}
