# Shidoku — personal Visual Intelligence app (owner: Pakē)

Camera-first iPhone app (Apple Visual Intelligence parity: Ask / shutter /
Search bottom bar). **Ask** = Claude answer in the sheet. **Search** (v1,
owner request 2026-07-13) = hand the frame to Google Lens. Do not add
features unprompted.

DELIVERY (owner's decision 2026-07-09): **native iOS shell via Capacitor**,
built unsigned on GitHub macOS runners, sideloaded with AltStore (free Apple ID,
7-day re-sign). See NATIVE.md for the whole pipeline. The Safari/PWA route is
abandoned as primary (owner: "too many restrictions") but index.html remains a
working web app and the single source of truth — the shell wraps it verbatim.

## Owner rules (non-negotiable)
- English only — UI, prompts, responses, comments. Zero Chinese or Japanese characters anywhere.
- The app must open straight into the live viewfinder: zero taps after launch.
- Mechanism-first answers, no filler praise (already baked into ASK_PROMPT).

## Empirical invariants (established on-device — do not re-test)
- claude.ai artifacts cannot use getUserMedia (iframe permissions policy) → PWA on own VPS.
- Live viewfinder requires HTTPS (secure context); Caddy in front is mandatory.
- The stream dies when backgrounded: stop on visibilitychange hidden, restart on visible.
- Fallback when live view is denied: `<input type="file" accept="image/*" capture="environment">`
  opens the iOS rear camera directly.
- iPhone HEIC: decode via `<img>` → canvas → JPEG (Safari decodes HEIC natively).
- `<video>` needs `playsinline muted autoplay`; layout uses viewport-fit=cover + env(safe-area-inset-*).

## Architecture
- index.html (whole app, vanilla JS) → same-origin POST /api/claude → server.py
  (stdlib-only Python relay: serves static files AND runs the brain as
  headless **persistent `claude -p` processes** — the owner's Claude
  subscription, NO API key anywhere). Latency architecture (all four matter;
  don't regress any): (1) `--input-format stream-json` keeps ONE process per
  capture alive — follow-ups are new stdin lines, no re-boot; (2) a POOL spare
  is pre-spawned AND **primed with a throwaway turn** (the CLI inits lazily on
  first message — an unprimed spare saves almost nothing); (3) the image rides
  INLINE in the first message (no Read tool, no extra model turn, no temp
  files); (4) `--system-prompt` replaces Claude Code's ~15k-token default
  (prefill was the bulk of first-token latency) and `--strict-mcp-config`
  skips MCP loading. `--allowedTools WebSearch` covers the Kleenex problem
  (exact/everyday names verified on the web in-answer). If the relay or a
  process died mid-thread, the handler rebuilds context in one message from
  the client's full history. The claude CLI must be installed and logged in
  wherever the relay runs.
- **Streaming**: relay → app is NDJSON, one JSON per line:
  `{"t":"delta","text"}` (incremental), `{"t":"sources","items":[{title,url}]}`,
  `{"t":"done"}`, `{"t":"error","message"}`. Errors are in-stream (HTTP is
  always 200 once streaming starts). The client renders markdown progressively
  per delta and shows sources as glass chips (the claude brain currently emits
  no sources event). The subprocess speaks
  `--output-format stream-json --include-partial-messages --verbose`; the relay
  forwards text_deltas, falls back to whole assistant blocks if partials are
  unsupported, and hard-kills a wedged subprocess after 240s. Nested-session
  env markers (CLAUDECODE*/CLAUDE_CODE_*) are scrubbed before spawning.
- Measured latency (2026-07-13, sonnet, hot pool, 1100px frame, REAL
  ASK_PROMPT payload): first Ask ~1.7-2.1s to first delta / ~6s done
  (long answer streams while reading); follow-ups ~2.2s. Two silent killers
  found by timestamping the event stream — both must STAY fixed:
  (1) extended thinking was on by default = 6+ mute seconds → spawn env sets
  MAX_THINKING_TOKENS=0 (the owner's v1 spec always said thinking off);
  (2) "verify names with web search" prompting made the model search things
  it already knew (~3s wasted) → both prompts now say search ONLY when it
  cannot confidently name the thing or the fact is current. History: naive
  spawn-per-request + Read tool + thinking + eager search = 8-21s first word.
  Frames are downscaled to 1100px client-side (frameToJpeg MAX) — fewer
  vision tokens is a real first-token win; don't raise it without remeasuring.
- **Search v1**: app POSTs the frozen frame to /api/lens → relay stores it in
  memory (10-min TTL, 30 cap) → returns `lens.google.com/uploadbyurl?url=`
  pointing at the relay's /frame/<id>.jpg → app window.opens it (the tab is
  opened synchronously inside the tap or popup rules eat it). Google fetches
  the frame inside the USER's own session. Set PUBLIC_URL env (or --public)
  to the server's public base on deploy; Google cannot fetch LAN addresses,
  so Search completes only once the app lives on the VPS. DO NOT upload to
  Google's endpoints instead — browsers get 403 on lens.google.com/v3/upload
  and /searchbyimage/upload, and a server-side anonymous upload mints a link
  the logged-in browser refuses ("image not associated with your account");
  all three verified 2026-07-13.
- **Capture light (native, since build #11)**: the capture/thinking/launch
  glow renders NATIVELY in the Capacitor shell. native/ShidokuGlow.swift is
  appended to AppDelegate.swift by ios.yml (no pbxproj surgery) and the
  storyboard is re-pointed at ShidokuViewController — a CAPBridgeViewController
  subclass that mounts a Core Animation overlay above the webview and registers
  the `shidokuGlow` WKScriptMessage channel before the page loads (both greps
  in the ios.yml step fail the build if the Capacitor template changes shape).
  index.html posts "bloom" / "think" / "idle" / "hello"; when the channel is
  absent (web, sim) the CSS #glow takes over unchanged. The light is built
  from the owner's real Apple VI recording, frame-measured: NOT a border ring —
  seven very large soft radial masses centered ON the screen border
  (screen-blended, falloff bleeding ~35% inward), igniting staggered over
  ~1.1 s on capture, breathing desynchronized while thinking, colors
  reshuffled every capture. The photo blur/brighten stays CSS in the webview.
  prefers-reduced-motion suppresses both paths; the overlay's layer clock is
  paused when idle so the drift loops cost nothing.
- The CLIENT stays vendor-neutral (Anthropic-shaped content blocks in `messages`).
  Changing brains = rewriting server.py's translation only.
- Brain history: Claude Sonnet 5 API (v1 design) → Gemini via OpenAI-compat
  (2026-07-09) → native Gemini + grounding + streaming (2026-07-11) →
  **claude -p headless (2026-07-13**, owner: "don't want to bother with Gemini
  anymore"; Claude's collocations are better and his subscription means no key
  top-ups; Gemini free-tier grounding turned out permanently 429'd anyway).
  MODEL default "sonnet" (fast); "opus" richer/slower. The Gemini relay code
  lives in git history (commit 3cf5a07 and earlier) if ever needed.
- Multi-turn: resend the full messages array; the image rides only in the first user message.
- ASK_PROMPT (index.html) is English-learner-first: lead with the everyday
  American name incl. genericized trademarks, collocations, compact-by-default.
  Don't flatten it back to generic captioning. **It deliberately names NO
  example brands** (owner decision 2026-07-13): the old "(tissues are
  'Kleenex', swabs are 'Q-tips'...)" line pre-fed answers and made his own
  tests unprovable. The category instruction alone triggers the reflex —
  verified: with examples stripped, the model still volunteered "Kleenex...
  universally used regardless of brand" from its own knowledge, unsearched.
  Do not re-add brand examples.
- Config knobs: RELAY, MAX_TOKENS, ASK_PROMPT in index.html; MODEL / PORT /
  HOST / TLS / PUBLIC_URL / CLAUDE_BIN in server.py (all env- or flag-
  overridable).

## Deploy
Local (the owner's PC, current daily driver): double-click
Documents\start-shidoku.bat → relay on :8790, LAN-reachable (--host 0.0.0.0).
The PC's claude CLI login is the brain; no keys.
VPS (future): `python3 server.py --port 8790 --public https://<domain>` behind
Caddy for HTTPS — **plus the claude CLI installed and logged in on the VPS**
(this replaced the old zero-install-VPS story when the brain moved to
claude -p; budget for a Node/npm or native-binary install + one interactive
`claude login`). Owner is in mainland China: the phone talks only to the VPS.
Plain HTTP on the phone = NO live viewfinder (secure-context rule — not a UI
bug; the shutter falls back to the iOS system camera). For the full zero-tap
experience over LAN, add `--tls C:\Users\Parak\Documents\shidoku-tls`
(self-signed cert, SAN-bound to the PC's LAN IP — regenerate if the IP
changes; phone must trust it once via /ca.crt served on PORT+1).

## History
HANDOFF.md is the original design record. Its §2 constraints and §3 architecture
remain valid; its Traditional-Chinese UI and multi-mode direction (translate /
lookup / event / reading / vocab...) was superseded 2026-07-08 — owner wants
English-only, Ask-only v1. Old mode prompts stay in HANDOFF.md §5 as reference.
