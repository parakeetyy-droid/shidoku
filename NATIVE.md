# Shidoku as a native iOS app (SwiftUI + GitHub Actions + Sideloadly)

Since 2026-07-14 the app is FULLY native SwiftUI (`ios-native/`) — the
Capacitor/WKWebView shell and the web UI are retired (git history ≤ 8f3742e).
GitHub's macOS-26 runners build an **unsigned IPA**; **Sideloadly** on the
Windows PC signs it with the owner's free Apple ID and installs it over USB.
Free-tier signatures expire every **7 days**.

## How the pieces map
- `ios-native/project.yml` — the whole project definition. The runner turns
  it into `Shidoku.xcodeproj` with xcodegen; nothing Xcode-generated is
  committed. Info.plist keys (camera, local network, ATS-allow, portrait
  lock) live HERE.
- `ios-native/Sources/` — the app. Config.swift (RELAY address, ASK_PROMPT),
  CameraController/CameraPreview (AVFoundation viewfinder + instant frame
  grab), GlowOverlay (the SETTLED capture light), ContentView (state machine),
  AnswerCard / BottomBar / CaptureControls (the VI-parity UI, measured in
  `Desktop\shidoku\UI-ANALYSIS.md`), RelayClient (NDJSON streaming),
  Markdown (answer rendering).
- `.github/workflows/ios.yml` — brew install xcodegen → copy assets/icon.png
  into the asset catalog → xcodegen → unsigned xcodebuild (Xcode 26 /
  iOS 26 SDK — `.glassEffect` needs it) → zip → IPA artifact. The package
  step greps the built Info.plist for the camera + local-network keys and
  fails loudly if they vanish.
- `server.py` — unchanged; the brain. The native app speaks the same
  protocol the web client did (POST /api/claude → NDJSON stream;
  POST /api/lens → results URL opened in an in-app Safari sheet).

## Building and shipping
1. Commit + push (`master`).
2. GitHub → Actions → "iOS build (unsigned IPA for AltStore)" → Run workflow
   (~3–6 min; native builds are slower than the shell era).
3. Download the artifact, VERIFY content (unzip; check Payload/Shidoku.app
   binary contains a fresh symbol, plist has NSLocalNetworkUsageDescription),
   stage as `Documents\shidoku\Shidoku-v<N>.ipa` (new number every build —
   Sideloadly re-signs its cached copy of a previously selected file).
4. Sideloadly: iPhone via USB → freshly pick the new vN → Start →
   app-specific password. VPN fully off during signing.
5. First launch after a (re)install: if Ask/Search says "Load failed", it is
   the iOS Local Network permission — Settings → Privacy & Security →
   Local Network → Shidoku ON (if missing: reboot the phone, relaunch, Allow).

## Known truths
- iOS 26 minimum (his iPhone 17e) — the UI uses system Liquid Glass
  (`.glassEffect`) with no fallbacks by design.
- There is no simulator/browser test loop anymore; UI iteration = rebuild +
  sideload. The layout canon lives in UI-ANALYSIS.md so iterations are
  measured, not guessed.
- AltStore never worked on this PC (see HANDOFF); Sideloadly is the door.
- When the VPS goes live: change `Config.relay` to the https domain,
  rebuild, and ATS-allow can be dropped from project.yml.
