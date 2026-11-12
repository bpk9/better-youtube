import Foundation

var count = 0
func parse(_ text: String) -> YouTubeLink? { YouTubeLink.parse(URL(string: text)!) }
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    count += 1
    if !condition() { fatalError("Failed: \(label)") }
}
let id = "aqz-KE-bpKQ"
for base in ["https://www.youtube.com/watch?v=", "http://m.youtube.com/watch?v=", "https://music.youtube.com/watch?v=", "https://youtu.be/", "https://youtube.com/shorts/", "https://youtube.com/live/", "https://youtube.com/embed/", "https://www.youtube-nocookie.com/embed/", "https://youtube.com/v/", "betteryoutube://watch?v=", "betteryoutube://shorts/", "betteryoutube://youtube.com/watch?v="] {
    check(parse(base + id)?.videoID == id, base)
}
for (suffix, time) in [("&t=90",90.0), ("&t=1m30s",90), ("&start=90.5",90.5), ("#t=1h2m3s",3723), ("&time_continue=12",12), ("#1:30",90), ("&t=0&start=20",0), ("&t=-1&start=12",12)] {
    check(parse("https://youtube.com/watch?v=\(id)\(suffix)")?.start == time, suffix)
}
let wrapped = "betteryoutube://open?url=https%3A%2F%2Fyoutu.be%2F\(id)%3Ft%3D90%26autoplay%3D0%26end%3D95"
check(parse(wrapped)?.start == 90 && parse(wrapped)?.end == 95 && parse(wrapped)?.autoplay == false, "wrapped URL preserves query")
check(parse("https://youtube.com/attribution_link?u=%2Fwatch%3Fv%3D\(id)%26t%3D9")?.start == 9, "relative attribution")
check(parse("https://youtube.com/redirect?q=https%3A%2F%2Fyoutu.be%2F\(id)%3Ft%3D8")?.start == 8, "redirect")
for route in ["playlist?list=PLexample&index=3", "@creator/videos", "channel/UCexample", "c/creator", "user/creator", "results?search_query=hello", "clip/clipID", "embed/videoseries?list=PLexample", "feed/subscriptions"] {
    let link = parse("https://youtube.com/" + route)
    check(link != nil && link?.videoID == nil && link?.url.host == "m.youtube.com", route)
}
let playlist = parse("https://youtu.be/\(id)?list=PLabc&index=3&si=tracking")!
check(playlist.url.absoluteString.contains("list=PLabc&index=3") && !playlist.url.absoluteString.contains("tracking"), "playlist context")
for invalid in ["https://evil.com/watch?v=\(id)", "https://youtube.com.evil.com/watch?v=\(id)", "https://youtube.com@evil.com/watch?v=\(id)", "https://evil.com@youtube.com/watch?v=\(id)", "file://youtube.com/watch?v=\(id)", "javascript:alert(1)", "https://youtube.com:8443/watch?v=\(id)", "https://youtube.com/watch?v=tooShort", "https://youtube.com/watch", "https://youtu.be/\(id)/extra", "betteryoutube://open?url=https%3A%2F%2Fevil.com", "https://youtube.com/redirect?q=https%3A%2F%2Fevil.com", "betteryoutube://open", "https://youtube.com/playlist"] {
    check(parse(invalid) == nil, invalid)
}
for invalid in ["-2", "NaN", "inf", "1e6", "9999999999999999999999999", "1m2h", "1:99", "", "1sfoo"] {
    check(YouTubeLink.time(invalid) == nil, invalid)
}
check(parse("https://youtu.be/\(id)?start=90&end=20")?.end == nil, "end before start ignored")
check(parse("https://youtu.be/\(id)?t=NaN")?.start == 0, "bad time falls back to zero")
print("Passed \(count) YouTube link checks")
