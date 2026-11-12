# Open YouTube links in Better YouTube

Paste a YouTube URL into the app’s search field, or open a `betteryoutube:` URL from another app. Links work both when Better YouTube is closed and when it is already playing a video. A new link replaces the current selection, including when it points to a different time in the same video.

## Open from the iPhone Share Sheet

Create a Shortcut named **Open in Better YouTube**:

1. Enable **Show in Share Sheet** and accept **URLs**.
2. Add **Get URLs from Input** using **Shortcut Input**, then **Get Item from List** → **First Item**.
3. Add **URL Encode** to encode that URL.
4. Add a **Text** action containing `betteryoutube://open?url=` followed by the **URL Encoded Text** variable.
5. Add **Open URLs**, using the Text output.

In Safari or YouTube, share a video link and choose **Open in Better YouTube**. Include the timestamp in the shared URL to start there. A URL that does not contain a timestamp starts at the beginning; the app cannot infer the current playhead in another app.

The entire nested URL must be encoded, including `&` and `#`. For example:

```text
betteryoutube://open?url=https%3A%2F%2Fyoutu.be%2Faqz-KE-bpKQ%3Ft%3D90
betteryoutube://watch?v=aqz-KE-bpKQ&t=1m30s
betteryoutube://shorts/aqz-KE-bpKQ?t=30
betteryoutube://watch?v=aqz-KE-bpKQ&start=30&end=40&autoplay=0
```

Ordinary `https://youtube.com` and `https://youtu.be` links elsewhere on iOS do **not** automatically redirect to Better YouTube. Apple’s [universal links require an association hosted by the website owner](https://developer.apple.com/documentation/xcode/supporting-associated-domains); this app does not control YouTube’s domains. The app registers only its own scheme, leaving Google sign-in and the official YouTube app’s schemes intact. The app does not include a Safari extension or a Share extension; the Shortcut above is the Share Sheet entry point.

## Supported destinations

| Link | Behavior |
| --- | --- |
| `youtube.com/watch?v=…`, `youtu.be/…` | Open the selected video in the player. |
| `/shorts/…`, `/live/…`, `/embed/…`, `/v/…` | Open the video in the same player. Live availability and seeking depend on the stream. |
| Mobile, www, and music YouTube hosts; `youtube-nocookie.com/embed/…` | Normalize to the mobile YouTube player. |
| `t=90`, `t=1h2m3s`, `start=90`, `time_continue=90`, `#t=90`, `#1:30` | Seek after media is ready, including downloaded video and native-stream handoffs. Query `t` takes precedence over `start`, then `time_continue`, then the fragment. Invalid times are ignored. |
| `end=120` | Pause at the absolute video time, provided it is after the start. Native playback checks once per second; web playback checks about every 750 ms. |
| `autoplay=0` | Open at the requested time, paused. Other links request playback. |
| `/playlist?list=…`, video links with `list`/`index` | Show the playlist in the in-app YouTube browser. A video ID also opens that video; the playlist remains available to choose another. No native playlist queue or automatic next-video feature is added. |
| `/@handle`, `/channel/…`, `/c/…`, `/user/…`, `/results?search_query=…`, `/feed/…` | Open the destination in the visible in-app browser. Video links tapped there use the same timestamp-aware player. |
| `/clip/…` | Open YouTube’s Clip page in the browser; do not guess a video ID or clip boundaries. |
| `/attribution_link?u=…`, `/redirect?q=…` | Unwrap a bounded number of redirects, only when the destination is a supported YouTube URL. |

Playback availability, sign-in restrictions, captions, and other website features still depend on YouTube. Embed presentation options such as `loop`, `controls`, and caption parameters do not override the app’s playback settings. Start times beyond a finite video’s duration are clamped near its end; streams that cannot seek show a message after a bounded attempt.

## Validation

`bash scripts/test-links.sh` runs the Foundation-only Swift routing tests without launching a simulator. `node scripts/test-bridge.cjs` covers delayed media, timestamp application, autoplay ordering, ad transitions, end times, and playback regressions. The simulator tests include cold/warm native links and a real YouTube timestamp link; native tests use the existing local MP4 fixture described in [the iOS README](../ios/README.md).
