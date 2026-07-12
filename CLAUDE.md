# Shidoku — personal Visual Intelligence app (owner: Pakē)

Camera-first iPhone app (Apple Visual Intelligence parity: Ask / shutter /
Search bottom bar). **Ask** = Gemini answer in the sheet. **Search** (v1,
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
  (stdlib-only Python relay: serves static files AND translates the app's
  vendor-neutral body into NATIVE Gemini `streamGenerateContent?alt=sse` with
  **Google Search grounding** (`tools:[{google_search:{}}]`) always enabled —
  the model searches when names/facts matter and returns citations). API key
  ONLY in the GEMINI_API_KEY env var on the VPS — never in client code.
- **Streaming**: relay → app is NDJSON, one JSON per line:
  `{"t":"delta","text"}` (incremental), `{"t":"sources","items":[{title,url}]}`,
  `{"t":"done"}`, `{"t":"error","message"}`. Errors are in-stream (HTTP is
  always 200 once streaming starts). The client renders markdown progressively
  per delta and shows sources as glass chips. Grounding is native-endpoint-only
  (the OpenAI-compat endpoint rejects google_search — do not go back).
- **Free-tier grounding wall (verified 2026-07-13)**: with the owner's free key,
  ANY request carrying google_search 429s (RESOURCE_EXHAUSTED, no per-metric
  detail) while the same request without tools succeeds — on flash-lite AND
  flash-latest, with fresh daily quota. It was never the daily request quota.
  server.py therefore retries once WITHOUT tools on a 429 (safe: the 429 raises
  at open, before any NDJSON reached the app). Ungrounded answers just show no
  source chips; a paid key upgrades back to grounded automatically. Do not
  remove this fallback — without it every Ask dies on free tier.
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
- The CLIENT stays vendor-neutral (Anthropic-shaped content blocks in `messages`).
  Changing brains = rewriting server.py's translation only.
- Brain history: Claude Sonnet 5 (v1) → Gemini via OpenAI-compat (2026-07-09) →
  native Gemini + grounding + streaming (2026-07-11). MODEL default
  gemini-3.1-flash-lite (free-tier reliable; 3.5-flash richer but sheds free load).
- Multi-turn: resend the full messages array; the image rides only in the first user message.
- ASK_PROMPT (index.html) is English-learner-first: lead with the everyday
  American name incl. genericized trademarks (Kleenex/Q-tips/Band-Aids),
  collocations, compact-by-default. Don't flatten it back to generic captioning.
- Config knobs: RELAY, MAX_TOKENS, ASK_PROMPT in index.html; MODEL/UPSTREAM/PORT/
  HOST/TLS in server.py (all env- or flag-overridable; UPSTREAM override enables
  fake-upstream pipeline tests — see scratchpad test_stream_pipeline.py pattern).

## Deploy
VPS: `GEMINI_API_KEY=... python3 server.py` (systemd/pm2; python3 is preinstalled
on any distro — nothing to install), Caddy for HTTPS, then iPhone Safari → Allow
camera → Add to Home Screen. Owner is in mainland China: the phone talks only to
the VPS; the VPS talks to Google. Local test: `python server.py --key X --port 8790`;
add `--host 0.0.0.0` to reach it from the iPhone over LAN. Plain HTTP on the phone =
NO live viewfinder (secure-context rule — not a UI bug; the shutter falls back to the
iOS system camera). For the full zero-tap experience over LAN, add
`--tls C:\Users\Parak\Documents\shidoku-tls` (self-signed cert, SAN-bound to the PC's
LAN IP — regenerate if the IP changes; phone must trust it once via /ca.crt served
on PORT+1). Owner's key is free-tier; gemini-3.5-flash 503s under peak load —
`--model gemini-3.1-flash-lite` (or gemini-flash-latest) is the tested fallback.

## History
HANDOFF.md is the original design record. Its §2 constraints and §3 architecture
remain valid; its Traditional-Chinese UI and multi-mode direction (translate /
lookup / event / reading / vocab...) was superseded 2026-07-08 — owner wants
English-only, Ask-only v1. Old mode prompts stay in HANDOFF.md §5 as reference.
