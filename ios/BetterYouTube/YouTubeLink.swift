import Foundation

/// The same router handles pasted links, app URLs and links tapped inside YouTube.
struct YouTubeLink: Equatable {
    let url: URL
    let videoID: String?
    let start: Double
    let end: Double?
    let autoplay: Bool

    static func parse(_ input: URL, depth: Int = 0) -> YouTubeLink? {
        guard depth < 4, var c = URLComponents(url: input, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.port == nil else { return nil }
        let scheme = c.scheme?.lowercased() ?? ""
        let host = c.host?.lowercased() ?? ""
        func value(_ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
        if scheme == "betteryoutube", host == "open" {
            guard let raw = value("url"), let nested = URL(string: raw) else { return nil }
            return parse(nested, depth: depth + 1)
        }
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
        if scheme == "betteryoutube" {
            // Both betteryoutube://watch?v=… and betteryoutube://youtube.com/watch?v=…
            if !youtubeHosts.contains(host) && host != "youtu.be" {
                c.path = "/" + host + c.path
                c.host = "www.youtube.com"
            }
            c.scheme = "https"
        } else if scheme != "https" && scheme != "http" { return nil }
        let canonicalHost = c.host?.lowercased() ?? ""
        guard youtubeHosts.contains(canonicalHost) || ["youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(canonicalHost) else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        let path = "/" + parts.joined(separator: "/")
        if ["/redirect", "/attribution_link"].contains(path) {
            guard let raw = value(path == "/redirect" ? "q" : "u"),
                  let nested = URL(string: raw, relativeTo: URL(string: "https://www.youtube.com")!)?.absoluteURL else { return nil }
            return parse(nested, depth: depth + 1)
        }
        let id: String?
        if canonicalHost == "youtu.be" { guard parts.count == 1 else { return nil }; id = parts[0] }
        else if path == "/watch" { id = value("v") }
        else if parts.count == 2 && ["shorts", "live", "embed", "v"].contains(parts[0]) && parts[1] != "videoseries" { id = parts[1] }
        else { id = nil }
        if let id, id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) == nil { return nil }
        if id == nil {
            // Keep website-only destinations (including Clips) in the visible browser.
            let browserRoute = path == "/" || path == "/playlist" || path == "/results" ||
                parts.first?.hasPrefix("@") == true || ["channel", "c", "user", "clip", "feed"].contains(parts.first ?? "") ||
                path == "/embed/videoseries"
            guard browserRoute, !canonicalHost.contains("nocookie") || path == "/embed/videoseries" else { return nil }
            if path == "/playlist" || path == "/embed/videoseries" {
                guard let list = value("list"), !list.isEmpty else { return nil }
                c.path = "/playlist"
            }
        }
        let fragment = URLComponents(string: "https://youtube.com/?" + (c.fragment ?? ""))?.queryItems ?? []
        let fragmentTime = fragment.first { $0.name == "t" || $0.name == "start" }?.value ?? c.fragment
        let start = [value("t"), value("start"), value("time_continue"), fragmentTime].compactMap { $0.flatMap(time) }.first ?? 0
        let end = value("end").flatMap(time).flatMap { $0 > start ? $0 : nil }
        let autoplay = value("autoplay") != "0"
        c.scheme = "https"; c.host = "m.youtube.com"; c.fragment = nil
        if let id {
            c.path = "/watch"
            // Preserve context without forwarding tracking and arbitrary embed options.
            c.queryItems = [URLQueryItem(name: "v", value: id)] + (c.queryItems ?? []).filter { ["list", "index", "lc"].contains($0.name) }
        }
        guard let url = c.url else { return nil }
        return YouTubeLink(url: url, videoID: id, start: start, end: end, autoplay: autoplay)
    }

    static func time(_ raw: String) -> Double? {
        let text = raw.lowercased()
        var seconds: Double?
        if text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil { seconds = Double(text) }
        else if text.range(of: "^(?:[0-9]+h)?(?:[0-9]+m)?(?:[0-9]+(?:\\.[0-9]+)?s)?$", options: .regularExpression) != nil, !text.isEmpty {
            let regex = try! NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)([hms])")
            seconds = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reduce(0) { total, match in
                let number = Double((text as NSString).substring(with: match.range(at: 1)))!
                let unit = (text as NSString).substring(with: match.range(at: 2))
                return total + number * (unit == "h" ? 3600 : unit == "m" ? 60 : 1)
            }
        } else if text.range(of: "^[0-9]+:[0-5][0-9](?::[0-5][0-9])?$", options: .regularExpression) != nil {
            seconds = text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        // Bound untrusted values before passing them to CMTime or JavaScript.
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 31_536_000 else { return nil }
        return seconds
    }
}
