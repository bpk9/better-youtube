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
2. With SSH key access to your server, run `python3 scripts/deploy-companion.py --ssh root@YOUR_SERVER --directory /YOUR_DEDICATED_APPDATA_DIRECTORY`. Add `--identity ~/.ssh/YOUR_DEPLOY_KEY` when using a dedicated SSH key. The script transfers an explicit file allowlist over SSH, restricts private-file permissions, gives the container UID access to its state and TLS key, and waits for Docker health. It requires Docker Compose with `--wait` support. Reuse this command for updates; do not regenerate pairing for ordinary deployments.
3. Run `python3 scripts/verify-companion.py --video aqz-KE-bpKQ`. It verifies the exact certificate pin before sending the token, checks authentication, prepares a real video, and checks MP4 bytes and resumed transfers. The video remains in the normal bounded cache.
4. Rebuild and install the iPhone app. `ios/BetterYouTube/Connection.plist` contains the private pairing token and pinned certificate fingerprint and must remain outside source control. Open Downloads and verify “Companion connected,” then download and play a video offline.

The Docker build context is allowlisted by `.dockerignore`; pairing credentials, certificates, runtime data, and media never enter the build context. Deployment uses a dedicated `better-youtube` Compose project. Local pairing files must match the deployed server before installing the app.

The service binds to the supplied address on TCP 8447. `--host` is the IP address or DNS name the iPhone connects to. `--bind-ip` is a numeric address assigned to the Docker host; it defaults to `--host` for numeric hosts and is required for DNS names. Wildcard bind addresses are rejected. TLS uses a private certificate whose exact fingerprint the app pins. No root certificate needs to be installed on the phone. Do not expose this port on the public Internet. Changing the service hostname/certificate requires updating the paired app configuration and rebuilding/installing the app.

`prepare-companion.py` generates a new certificate unless you pass `--reuse-certificate`, which requires an existing certificate and key. Run it deliberately: existing app builds pin the previous certificate. It preserves the token, server settings, and any Google client ID already configured. Stop a running local test service before regenerating its certificate.

## Tailscale access away from home

Install and connect Tailscale on the **Docker host** and iPhone in the same tailnet. This setup uses the host's Tailscale interface; a separate Tailscale container in userspace networking mode does not provide an address Docker can bind on the host. Ensure Tailscale is connected before starting the companion, including after a server reboot. Your tailnet access policy must allow the iPhone to reach the server on TCP 8447.

On the server, run `tailscale ip -4` to find its Tailscale address. From this repository on your Mac, pair with that address (the values below are examples):

```sh
python3 scripts/prepare-companion.py --host 100.101.102.103
```

To use the server's full [MagicDNS name](https://tailscale.com/docs/features/magicdns), supply its Tailscale IP separately for Docker:

```sh
python3 scripts/prepare-companion.py \
  --host companion.example.ts.net --bind-ip 100.101.102.103
```

Use the actual server name shown in Tailscale, with MagicDNS enabled. Both options bind only to the specified Tailscale address. The phone needs Tailscale connected at home as well as away. No exit node, public port forwarding, Tailscale Serve, or Funnel is needed; connect directly to the companion's pinned HTTPS service on port 8447. A TLS-terminating proxy presents a different certificate and fails the existing pin.

When migrating an existing paired companion, append `--reuse-certificate` to either command. This keeps the certificate, private key, token, Google configuration, and server settings. The app authenticates the exact pinned certificate rather than its hostname, so an existing LAN certificate can be reused with the Tailscale endpoint. The changed endpoint still requires an app rebuild/install. Keep a backup of the ignored pairing files before migration if you need to roll back to the LAN endpoint.

Deploy with `scripts/deploy-companion.py` as above, then connect the Mac to the same tailnet and run:

```sh
python3 scripts/verify-companion.py
```

This checks the certificate pin and authenticated API through the configured Tailscale endpoint. Add `--video aqz-KE-bpKQ` to verify media preparation and resumed downloads. Rebuild/install the iPhone app, connect Tailscale, turn off Wi-Fi to test away-from-home access, and open Downloads to check “Companion connected.” Downloads default to Wi-Fi only: turn off **Download on Wi-Fi only** in the app's Downloads settings when testing media transfers over cellular. Already downloaded files work without Tailscale or a network connection.

For DNS hosts, setup writes an ignored `ios/Config/Companion.local.xcconfig` setting used by `Info.plist` to permit [manual server trust evaluation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsexceptionallowsinsecurehttploads) for that exact host. The app still requires HTTPS, the matching certificate fingerprint, and the pairing token for API calls and background downloads. The exception does not include subdomains or other tailnet hosts.

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
