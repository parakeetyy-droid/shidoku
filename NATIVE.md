# Shidoku as a native iOS app (Capacitor + GitHub Actions + AltStore)

The native app is a thin WKWebView shell (Capacitor) around the same `index.html`.
GitHub's free macOS runners build an **unsigned IPA**; **AltStore** on the Windows PC
signs it with an ordinary (free) Apple ID and installs it. Free-tier signatures
expire every **7 days** — AltStore auto-refreshes when the phone is on the same
Wi-Fi as a running AltServer.

## How the pieces map
- `index.html` — the whole app, shared verbatim with the web version. In the shell,
  `location.protocol` isn't http(s), so `RELAY` switches to an absolute URL
  (the PC on Wi-Fi now, the VPS later — one constant).
- `package.json`, `capacitor.config.json` — the shell definition. The `ios/` project
  is generated fresh on the runner each build (never committed).
- `.github/workflows/ios.yml` — the cloud build: assemble `www/`, `cap add ios`,
  generate icons from `assets/`, patch Info.plist (camera permission, ATS-allow so
  plain-http LAN relay works, portrait lock), `xcodebuild` unsigned, zip → IPA artifact.
- `server.py` — unchanged. For the native app on LAN, run it plain-HTTP:
  `python server.py --key <KEY> --host 0.0.0.0 --port 8790`

## One-time setup (owner)
1. **GitHub**: create account (VPN helps) → create empty repo `shidoku` →
   `git remote add origin https://github.com/<USER>/shidoku.git` → `git push -u origin master`
   (Git Credential Manager pops a browser login). Public repo = unlimited free build minutes.
2. **Build**: GitHub → repo → Actions tab → "iOS build (unsigned IPA for AltStore)" →
   Run workflow → wait ~10 min → download the `Shidoku-ipa` artifact (zip with Shidoku.ipa).
3. **AltStore** (altstore.io, classic AltStore — not the EU-only PAL version):
   - Install **iTunes and iCloud from Apple's website** (NOT the Microsoft Store versions —
     AltServer requires the non-Store builds).
   - Install AltServer on the PC; iPhone via USB, "Trust this computer".
   - Generate an **app-specific password** at appleid.apple.com (needs 2FA).
   - AltServer tray icon → Install AltStore → your Apple ID + that app-specific password.
   - On the phone: trust the developer profile (Settings → General → VPN & Device Management).
   - AltStore app → "+" → pick the downloaded Shidoku.ipa → installs with your icon.
4. **Weekly**: have AltServer running while the phone is on home Wi-Fi; AltStore
   refreshes signatures in the background. (Free Apple ID limits: 3 sideloaded apps,
   7-day signature life.)

## Updating the app later
Edit `index.html` → commit → push → run the workflow → download IPA → AltStore "+" again.

## Known risks / plan B
- `getUserMedia` (live viewfinder) inside Capacitor's WKWebView works on modern iOS with
  the camera permission patched in — but if the viewfinder misbehaves in the shell, the
  drop-in fix is the `@capacitor-community/camera-preview` native plugin.
- First CI run may need an iteration or two (Capacitor/Xcode version drift) — read the
  Actions log and fix `ios.yml`, don't fight it locally.
- When the VPS is live, change the `RELAY` native URL in index.html to
  `https://<domain>/api/claude` and rebuild; ATS-allow can then be dropped from ios.yml.
