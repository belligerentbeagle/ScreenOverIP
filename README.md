# Screen Over IP

**Extend your Mac display onto ANY display over web!**

Your car's display, your TV, your fridge door, your spare laptop, a public computer, anything that can open a web page. Pick a display or window, hit Start, share the URL. With one toggle you can also expose it as a `https://*.trycloudflare.com` URL that works from anywhere on the internet, password-protected.

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

```bash
brew install xcodegen
./setup.sh        # generates project and opens Xcode
```

Press `⌘R` in Xcode. Pick a display or window, hit **Start streaming**, grant Screen Recording when prompted. Open the URL (or scan the QR code) on any device on the same Wi-Fi.

**Optional add-ons:**

- **Extended desktop** — `brew install --cask betterdisplay`, create a virtual screen, pick it in the dropdown.
- **Public internet URL** — `brew install cloudflared`, restart app, toggle **Expose via Cloudflare Tunnel**. A `https://*.trycloudflare.com` URL appears within ~10s.
- **Password** — toggle **Require password** in the Security section before sharing publicly.

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

**High latency** — Wi-Fi baseline is 100–400ms. If higher, drop Max width to 960 or JPEG quality to 60%.

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
