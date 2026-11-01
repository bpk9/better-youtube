# Better YouTube companion

Private, single-user service for preparing YouTube MP4 files and monitoring selected channels. The app stores Google OAuth tokens on the iPhone; the companion receives only public channel IDs and requested video IDs.

## Resource budget

- One download worker; one fragment at a time; 4 MB/s transfer limit.
- Downloads a compatible MP4 with audio already included, up to 720p. Commonly available files are 360p. No FFmpeg or transcoding.
- Videos limited to two hours and 500 MB; live streams skipped.
- 5 GB server cache; files expire after seven days; bounded queue of 100 jobs.
- Channel RSS polling every 30 minutes, up to 100 channels.
- Docker limits: half a CPU core, 512 MB RAM, 80 processes, 10 MB rotating logs.
- No database service, browser process, GPU, public endpoint, or Google cookies.

## Pair and deploy

1. Run `python3 scripts/prepare-companion.py --host YOUR_SERVER_LAN_IP` from the project root. Optionally add `--google-client-id YOUR_IOS_CLIENT_ID`.
2. Copy `server/` (including private `.env` and `tls/`, excluding local test state) to a dedicated directory on your server. Keep `.env` and `tls/key.pem` private. Create `state/` owned by container UID 10001, and give that UID read access to the TLS key. Do not make the key world-readable.
3. Run `docker compose up -d --build` in that directory. Use a dedicated project; this compose file does not modify other containers.
4. Rebuild and install the iPhone app. `ios/BetterYouTube/Connection.plist` contains the private pairing token and pinned certificate fingerprint and must remain outside source control.

The service binds to the supplied LAN address on TCP 8447. TLS uses a private certificate whose exact fingerprint the app pins. No root certificate needs to be installed on the phone. Do not expose this port on the public Internet. To connect away from home, use an existing private VPN; changing the service hostname/certificate requires updating the paired app configuration.

`prepare-companion.py` generates a new certificate each time. Run it deliberately: existing app builds pin the previous certificate. It preserves the token and any Google client ID already configured. Stop a running local test service before regenerating its certificate.

## Google setup

The iOS app needs a Google Cloud OAuth client with application type **iOS**, the bundle ID you chose in `ios/Config/Local.xcconfig`, and the YouTube Data API v3 enabled. Configure the consent screen for your app and add the account as a test user if the project is in testing mode. Supply the iOS client ID to the pairing script; no client secret belongs in the app. Sign-in uses the system authentication browser, PKCE, state validation, and the read-only YouTube scope. Tokens stay in Keychain.

To configure Google independently of the companion, run `python3 scripts/configure-google.py --client-id IOS_CLIENT_ID` from the project root, then rebuild/install. This preserves server pairing and existing URL handlers while registering the reversed-client-ID callback scheme in ignored local configuration. Do not rerun companion certificate generation just to configure sign-in.

The native connection imports subscriptions. Google's Data API does not supply YouTube's personalized Home feed; website recommendations still depend on the separate WebKit website session. The app labels its signed-out discovery fallback and its channel-upload feed distinctly.

## Automatic-download behavior

The first check of an enabled channel establishes a baseline without downloading its existing backlog. Subsequent new entries enqueue exactly once. Disabling and re-enabling starts a new baseline. A failed feed fetch keeps its previous checkpoint so a temporary outage doesn't discard unseen videos. Failures retry with backoff, with a maximum of three preparation attempts. MP4 files support HTTP Range for resumed iPhone transfers.

The server can prepare videos while the app isn't open. It cannot force iOS to fetch a new file immediately: the app schedules background refresh, and background URLSession continues transfers that have already been queued. Opening the app immediately checks for new prepared files. Force-quitting the app may stop transfers until the next launch. No APNs or paid push service is configured.

Offline files on the iPhone are limited to 2 GB and aren't silently evicted. Removing a file suppresses automatic re-download of that same video; manually requesting it again clears that suppression. Removing from the iPhone doesn't delete the server cache, which expires independently.

## Tests and maintenance

Run `python3 -m unittest discover -s server -p test_app.py -v` from the repository root. Tests cover authentication, duplicate requests, path/SSRF rejection, channel baselines, one-time new-upload queuing, HTTP Range, cache expiration, and restart recovery. Real media download must also be verified because YouTube changes independently of these tests.

yt-dlp and its bundled JavaScript solver are pinned in `requirements.txt`; update them deliberately if YouTube extraction stops working. Errors appear on the download item, and signed media URLs are removed from persisted error messages.
