# Screen Over IP

**Extend your Mac to any display — over the web.**

Stream your screen to any browser via a URL: your phone, your iPad, a friend's laptop, your car's infotainment display, anything that can open a web page. Pick a display or window, hit Start, share the URL. With one toggle you can also expose it as a `https://*.trycloudflare.com` URL that works from anywhere on the internet, password-protected.

---

## What you can do with it

- **Mirror a display or window** to any browser on your local network.
- **Extend your desktop** by pairing it with [BetterDisplay](https://github.com/waydabber/BetterDisplay) — drag windows onto a virtual screen that lives in a browser tab.
- **Stream over the internet** with one click, via an embedded Cloudflare Tunnel — no router config, no static IP, automatic HTTPS.
- **Password-protect** the stream so only people with the credential can watch.
- **Multiple viewers** at the same time. They all see the same stream.
- **No plugins, no installs on the receiving device.** Just open the URL.

The browser side is intentionally view-only — viewers can't control your Mac.

---

## Quickstart

1. Build and run the app (see "Setting it up" below the first time).
2. Pick a **Display** or **Window** in the source dropdown.
3. Press **Start streaming**.
4. The first time, macOS asks for Screen Recording permission. Grant it, then press Start again.
5. Open the URL the app shows — on your phone, iPad, another Mac, anything on the same Wi-Fi.

There's a QR code at the bottom; point a phone camera at it and tap the link.

---

## Setting it up

### 1. Build the app (one-time)

The repo doesn't ship a prebuilt `.app` — you'll need Xcode to build it once.

```bash
brew install xcodegen          # generates the Xcode project from project.yml
cd ~/Documents/Claude/Projects/ScreenOverIP
./setup.sh                     # generates the project and opens Xcode
```

In Xcode press `⌘R` to build and run. (If `./setup.sh` doesn't open Xcode, see [Troubleshooting](#troubleshooting).)

You only need to do this once — after the first build, you can launch ScreenOverIP from `~/Library/Developer/Xcode/DerivedData/.../Products/Debug/ScreenOverIP.app` like any other app, or drag it to `/Applications/`.

### 2. Grant Screen Recording permission

The first time you press **Start streaming**, macOS asks for permission to record your screen. Click **Allow**.

If you accidentally said no, fix it under **System Settings → Privacy & Security → Screen Recording** — toggle ScreenOverIP on, then quit and relaunch the app.

### 3. (Optional) Set up an extended display

By default ScreenOverIP mirrors a screen you already have. To get a real *extended* desktop — a separate workspace you drag windows onto — pair it with [BetterDisplay](https://github.com/waydabber/BetterDisplay), an open-source virtual-display tool.

```bash
brew install --cask betterdisplay
open /Applications/BetterDisplay.app
```

In BetterDisplay's menu bar icon, choose **Create new virtual screen** and pick a resolution. macOS now sees a second monitor. Open **System Settings → Displays → Arrange** to position it (left of, right of, above your real screen — wherever feels natural).

In ScreenOverIP, hit **Refresh sources** and pick the new virtual display from the dropdown. Drag windows past the edge of your real display in the direction you placed it; they appear on the virtual screen, which the remote browser is now showing.

To remove the virtual screen later: BetterDisplay menu → trash icon next to the dummy entry.

### 4. (Optional) Public URL over the internet

For viewers who aren't on your Wi-Fi — phones on cellular, friends across the country, your car's browser — flip on **Expose via Cloudflare Tunnel** in the app. It needs `cloudflared` installed once:

```bash
brew install cloudflared
```

Restart ScreenOverIP. The "Public URL" section switches from the install hint to a toggle. Enable it and press Start; after 5–15 seconds, a `https://*.trycloudflare.com` URL appears in the URL section. Type that URL into the remote device's browser and you're streaming over the public internet with HTTPS.

The URL is ephemeral — every run gets a fresh one. (Stable URLs on your own domain are on the roadmap.)

### 5. (Optional, but please) Password protection

Public URL = anyone with the link can watch your screen. Don't do that without a password. In the **Security** section, toggle **Require password** on, type a password (or leave the field blank and the app generates a 12-character random one). The browser prompts for it on first connect.

The active credentials are shown under the URL section while streaming, so you can read them off and type them into the remote device.

---

## Using the app day-to-day

Once it's set up, the flow is just:

1. Launch ScreenOverIP.
2. Pick the source you want to stream (display, window, or virtual screen).
3. Adjust **Frame rate**, **JPEG quality**, and **Max width** to taste — see [Data usage](#data-usage) for the tradeoffs.
4. (If you'll be sharing publicly) flip on **Require password** and **Expose via Cloudflare Tunnel**.
5. Press **Start streaming**.
6. Open the URL on the remote device. The viewer page has a Fullscreen button in the bottom-right.

The window in the app shows you who's watching (subscriber count) and the current login credentials.

---

## Data usage

ScreenOverIP uses MJPEG — every frame is a fresh JPEG with no inter-frame compression. Bandwidth is the same on the sender's outbound and the viewer's inbound; the same compressed bytes travel both ways unmodified.

| Settings (width × fps × quality) | Per-frame JPEG | Bitrate | Per minute | Per hour |
|---|---|---|---|---|
| 640 × 15 fps × 50% | ~30 KB | ~3.6 Mbps | ~27 MB | ~1.6 GB |
| 1280 × 30 fps × 70% (default) | ~120 KB | ~29 Mbps | ~215 MB | ~13 GB |
| 1920 × 30 fps × 70% | ~250 KB | ~60 Mbps | ~450 MB | ~27 GB |
| 2560 × 30 fps × 80% | ~500 KB | ~120 Mbps | ~900 MB | ~54 GB |

Real numbers vary ±50% depending on content. Static UIs (terminal, document) compress smaller; full-screen video is close to worst-case.

A few practical implications:

- **Mac's outbound** scales linearly with the number of viewers. Two browsers connected = double the upload. The Mac encodes once and broadcasts.
- **Viewer's inbound** is just the bitrate column above, regardless of how many other viewers exist.
- **Cellular plans** care about the "per hour" column. The default settings will eat ~13 GB/hour of cellular data — fine on Wi-Fi, brutal on a metered plan. For a car-display use case, drop to 640 × 15 fps × 50% (~1.6 GB/hour).
- **Cloudflare quick tunnels** don't publish a hard cap, but Cloudflare throttles abusers; sustained tens of Mbps for hours has been reported to slow down. Fine for an evening's streaming, not for 24/7 use.

If/when WebRTC support lands, expect bandwidth at default settings to drop by roughly 5×.

---

## Troubleshooting

**"No sources detected" or "grant Screen Recording permission" — but I already did.**
This is almost always a permission cache issue, not your settings. The Mac caches permission grants by binary signature; rebuilds re-sign and macOS treats the new binary as a different app. Fix:

```bash
tccutil reset ScreenCapture com.screenoverip.app
```

Quit the app, relaunch from Xcode, click Allow on the new prompt. If `tccutil` doesn't help: System Settings → Privacy & Security → Screen Recording → click `−` to **remove** ScreenOverIP entirely (don't just toggle it), then re-launch.

**`./setup.sh` ran but Xcode didn't open.**
Xcode probably isn't installed. Confirm with `open -a Xcode`. If it errors, install Xcode from the Mac App Store. Command Line Tools alone aren't enough.

**`brew install --cask betterdummy` says it's already installed.**
Homebrew renamed `betterdummy` to `betterdisplay` (same author, superset of features). Just `open /Applications/BetterDisplay.app` and use that.

**"Stream interrupted. Retrying…" in the browser.**
Either you stopped the stream on the Mac, the network briefly dropped, or the viewer is too slow to keep up. The browser auto-reconnects every 1.5s.

**The public URL hangs / never gets a response.**
cloudflared can take 5–15 seconds the first time. If it stays starting for over 30 seconds, check Console.app for cloudflared logs — most often it's a network filter (corporate VPN, DNS adblocker) blocking outbound to Cloudflare.

**Cloudflare Tunnel says "tunnel error" with a non-zero exit code.**
Make sure the version is current: `brew upgrade cloudflared`. Older builds occasionally fail to register with Cloudflare's edge.

**Latency feels high.**
On Wi-Fi, expect 100–400ms. Higher than that usually means JPEG quality is too high — drop **Max width** to 960 or **JPEG quality** to 60%.

---

## Developer notes

### Project layout

```
ScreenOverIP/
├── project.yml                    # XcodeGen spec — generates ScreenOverIP.xcodeproj
├── setup.sh                       # one-liner: xcodegen generate + open in Xcode
├── README.md
└── ScreenOverIP/
    ├── ScreenOverIPApp.swift      # @main entry
    ├── ContentView.swift          # SwiftUI control panel + QR code
    ├── StreamCoordinator.swift    # @MainActor glue: capture → encoder → server
    ├── ScreenCapture.swift        # ScreenCaptureKit wrapper + Core Image JPEG encoder
    ├── HTTPServer.swift           # Network.framework HTTP/1.1 + MJPEG + Basic auth
    ├── CloudflaredTunnel.swift    # Subprocess manager for cloudflared
    ├── BonjourService.swift       # NetworkHelper (LAN IP / .local discovery)
    ├── Info.plist
    └── ScreenOverIP.entitlements
```

`project.yml` is the source of truth — `ScreenOverIP.xcodeproj` is generated and gitignored.

### Build it from scratch

```bash
brew install xcodegen
cd ScreenOverIP
xcodegen generate
open ScreenOverIP.xcodeproj
```

Or run `./setup.sh`, which does both and verifies Xcode is installed.

### Architecture in 30 seconds

`ScreenCapture` runs an `SCStream` configured with the chosen `SCContentFilter`. Frames arrive as `CVPixelBuffer`s on a dedicated capture queue. `JPEGEncoder` (a singleton wrapping a single `CIContext`) compresses each frame; the bytes are pushed to `HTTPServer.pushFrame`.

`HTTPServer` is built on `NWListener` from Network.framework. It accepts connections, parses HTTP/1.1 by hand, and routes:

- `/` → embedded HTML viewer (auto-reconnect, fullscreen, FPS hud)
- `/stream.mjpg` → `multipart/x-mixed-replace` MJPEG stream — connection stays open, every new JPEG broadcast as a part
- `/snapshot.jpg` → most recent JPEG once
- `/health` → `200 ok`

If `credentials` is set, every endpoint except `/health` gates on `Authorization: Basic`. Credentials are compared in constant time.

`CloudflaredTunnel` is a `Process` wrapper. It looks for the `cloudflared` binary (Homebrew paths and `which`), spawns it with `tunnel --no-autoupdate --url http://localhost:<port>`, and watches both stderr and stdout for an `https://*.trycloudflare.com` URL via regex. Termination is `terminate()` then `SIGKILL` after 3s if it doesn't exit.

`StreamCoordinator` is a `@MainActor ObservableObject` that owns those pieces and exposes `@Published` state to SwiftUI. The capture closure runs on a background queue, dispatches frame bytes through the server's serialization queue, and bounces UI updates back to MainActor through `Task { @MainActor in ... }`.

### TCC permission gotcha

Every fresh build re-signs with a different ad-hoc signature. macOS's Transparency, Consent, and Control database (TCC) keys Screen Recording grants on the binary's signature, not just the bundle ID. Result: after a rebuild the toggle in System Settings still shows "on" but TCC silently denies, and `SCShareableContent.excludingDesktopWindows` returns nothing.

Reset whenever you see "no sources detected":

```bash
tccutil reset ScreenCapture com.screenoverip.app
```

The error message in the app's UI now points at this command directly.

### Permissions / entitlements

In `Info.plist`:

- `NSScreenCaptureUsageDescription` — required, prompt copy.
- `NSLocalNetworkUsageDescription` — required so Bonjour publishing doesn't get blocked.
- `NSBonjourServices` → `_http._tcp` — lets us advertise the service to the LAN.

In the entitlements:

- `com.apple.security.app-sandbox: false` — required so we can spawn `cloudflared` as a subprocess. Sandboxed apps can't `Process.run()` arbitrary binaries.
- `com.apple.security.network.server: true` — listening sockets.
- `com.apple.security.network.client: true` — outbound to Cloudflare from the cloudflared subprocess.
- Hardened runtime is on (`ENABLE_HARDENED_RUNTIME = YES`) but we're not sandboxed, so subprocess spawning works.

### HTTP endpoints

| Path | Method | Description |
|---|---|---|
| `/` | GET | HTML viewer page. |
| `/stream.mjpg` | GET | `multipart/x-mixed-replace` MJPEG stream. |
| `/snapshot.jpg` | GET | Single most-recent JPEG frame. |
| `/health` | GET | Returns `ok`. Public even with auth on. |

### Roadmap

- WebRTC backend for ~5× lower bandwidth and audio.
- Named Cloudflare Tunnel support (stable URL on your own domain) instead of just quick tunnels.
- Optional input forwarding (mouse + keyboard from browser → Mac), gated behind explicit Accessibility prompts.
- Built-in virtual display creation (BetterDisplay-style) so step 3 of setup goes away.
- Menu bar mode (`LSUIElement = true`) for always-on use.
- HEVC / H.264 fragmented MP4 streaming as a bandwidth-efficient alternative to MJPEG.

### License

MIT.
