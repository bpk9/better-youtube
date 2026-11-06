import Foundation

struct ChannelVideoFeed {
    struct Result {
        let videos: [Video]
        let failedChannels: Int
        var message: String? {
            failedChannels == 0 ? nil : "Couldn’t refresh \(failedChannels) channel\(failedChannels == 1 ? "" : "s"). Pull to refresh to try again."
        }
    }

    enum FeedError: LocalizedError {
        case signInRequired
        case api(Int, String, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .signInRequired: return "Reconnect Google from the account screen to load your subscriptions."
            case .api(let status, let reason, let message):
                if status == 401 { return "Google access has expired. Reconnect from the account screen." }
                if ["quotaExceeded", "dailyLimitExceeded"].contains(reason) {
                    return "YouTube’s daily API limit has been reached. Try again later."
                }
                return "YouTube couldn’t load recent uploads. \(message)"
            case .invalidResponse: return "YouTube returned an unreadable uploads feed. Pull to refresh to try again."
            }
        }
    }

    private struct ChannelList: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                struct Playlists: Decodable { let uploads: String? }
                let relatedPlaylists: Playlists?
            }
            let id: String
            let contentDetails: Content?
        }
        let items: [Item]
    }
    private struct UploadList: Decodable {
        struct Item: Decodable {
            struct Snippet: Decodable { let title: String }
            struct Content: Decodable { let videoId: String; let videoPublishedAt: String? }
            struct Status: Decodable { let privacyStatus: String? }
            let snippet: Snippet?
            let contentDetails: Content?
            let status: Status?
        }
        let items: [Item]
    }

    /// Signed-in feeds use the Data API. Public RSS is only for signed-out discovery.
    static func load(_ channels: [ChannelRule], accessToken: String? = nil, session: URLSession = .shared) async throws -> Result {
        var seenChannels = Set<String>()
        let channels = channels.filter { seenChannels.insert($0.id).inserted }
        guard !channels.isEmpty else { return Result(videos: [], failedChannels: 0) }
        var playlists: [String: String] = [:]
        if let accessToken {
            for offset in stride(from: 0, to: channels.count, by: 50) {
                try Task.checkCancellation()
                let ids = channels[offset..<min(offset + 50, channels.count)].map(\.id).joined(separator: ",")
                let data = try await request("channels", query: ["part": "contentDetails", "id": ids, "maxResults": "50"], token: accessToken, session: session)
                let list = try JSONDecoder().decode(ChannelList.self, from: data)
                for item in list.items { playlists[item.id] = item.contentDetails?.relatedPlaylists?.uploads }
            }
        }
        let uploadPlaylists = playlists
        return try await withThrowingTaskGroup(of: Swift.Result<[Video], Error>.self) { group in
            var iterator = channels.makeIterator()
            func add(_ channel: ChannelRule) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        if let accessToken {
                            // Removed channels and channels without uploads are valid empty results.
                            guard let playlist = uploadPlaylists[channel.id] else { return .success([]) }
                            let data = try await request("playlistItems", query: ["part": "snippet,contentDetails,status", "playlistId": playlist, "maxResults": "15"], token: accessToken, session: session)
                            let list = try JSONDecoder().decode(UploadList.self, from: data)
                            return .success(list.items.compactMap { item in
                                guard let content = item.contentDetails, validVideoID(content.videoId),
                                      let published = content.videoPublishedAt, let snippet = item.snippet,
                                      item.status?.privacyStatus != "private" else { return nil }
                                return Video(id: content.videoId, title: snippet.title, channel: channel.title, detail: published, channelID: channel.id)
                            })
                        }
                        var url = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
                        url.queryItems = [URLQueryItem(name: "channel_id", value: channel.id)]
                        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
                        let (data, response) = try await session.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { throw FeedError.invalidResponse }
                        let reader = ChannelXMLReader(channel: channel)
                        let parser = XMLParser(data: data); parser.delegate = reader; parser.shouldResolveExternalEntities = false
                        guard parser.parse() else { throw FeedError.invalidResponse }
                        return .success(reader.videos)
                    } catch { return .failure(error) }
                }
            }
            for _ in 0..<4 { if let channel = iterator.next() { add(channel) } }
            var videos: [Video] = [], failed = 0
            var firstError: Error?
            for try await result in group {
                try Task.checkCancellation()
                switch result {
                case .success(let items): videos += items
                case .failure(let error):
                    // Stop immediately for account-wide failures instead of exhausting quota.
                    if case FeedError.api(let status, let reason, _) = error,
                       status == 401 || ["quotaExceeded", "dailyLimitExceeded"].contains(reason) { throw error }
                    failed += 1
                    if firstError == nil { firstError = error }
                }
                if let channel = iterator.next() { add(channel) }
            }
            if failed == channels.count, let firstError { throw firstError }
            let standard = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var seenVideos = Set<String>()
            let dated = videos.filter { seenVideos.insert($0.id).inserted }.map { video in
                (video, standard.date(from: video.detail) ?? fractional.date(from: video.detail) ?? .distantPast)
            }
            return Result(videos: dated.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.map(\.0), failedChannels: failed)
        }
    }

    private static func request(_ resource: String, query: [String: String], token: String, session: URLSession) async throws -> Data {
        var url = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(resource)")!
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let reasons = error?["errors"] as? [[String: Any]]
            throw FeedError.api(status, reasons?.first?["reason"] as? String ?? "", error?["message"] as? String ?? "Please try again later.")
        }
        guard data.count < 2_000_000 else { throw FeedError.invalidResponse }
        return data
    }

    fileprivate static func validVideoID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

private final class ChannelXMLReader: NSObject, XMLParserDelegate {
    let channel: ChannelRule
    var videos: [Video] = []
    private var inside = false, value = "", id = "", title = "", published = ""
    init(channel: ChannelRule) { self.channel = channel }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "entry" { inside = true; id = ""; title = ""; published = "" }
        value = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inside else { return }
        if elementName == "yt:videoId" { id = value }
        if elementName == "title" { title = value }
        if elementName == "published" { published = value }
        if elementName == "entry" {
            if ChannelVideoFeed.validVideoID(id) { videos.append(Video(id: id, title: title, channel: channel.title, detail: published, channelID: channel.id)) }
            inside = false
        }
    }
}
