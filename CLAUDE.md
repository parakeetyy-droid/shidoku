# Shidoku — personal Visual Intelligence PWA (owner: Pakē)

Camera-first iPhone home-screen PWA; the analysis brain is the Anthropic API
behind a VPS relay. v1 is ONE feature: the **Ask** button (Apple Visual
Intelligence parity: Ask / shutter / Search bottom bar). **Search is a
deliberate stub.** Do not add features unprompted.

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
  vendor-neutral body into an OpenAI-style chat request aimed at Gemini's
  OpenAI-compatible endpoint, generativelanguage.googleapis.com). API key ONLY
  in the GEMINI_API_KEY env var on the VPS — never in client code.
- The CLIENT is vendor-neutral (Anthropic-shaped content blocks; response contract:
  concatenate content blocks with type === "text"; errors read from error.message).
  Changing the brain vendor = editing server.py's UPSTREAM/MODEL/translation only.
- Brain history: Claude Sonnet 5 (v1) → Gemini (owner's decision 2026-07-09 after
  his own model research; MODEL default "gemini-3.5-flash" — env-overridable,
  confirm the exact id in AI Studio).
- Multi-turn: resend the full messages array; the image rides only in the first user message.
- Config knobs: RELAY, MAX_TOKENS, ASK_PROMPT at the top of index.html's script;
  MODEL + UPSTREAM at the top of server.py.

## Deploy
VPS: `GEMINI_API_KEY=... python3 server.py` (systemd/pm2; python3 is preinstalled
on any distro — nothing to install), Caddy for HTTPS, then iPhone Safari → Allow
camera → Add to Home Screen. Owner is in mainland China: the phone talks only to
the VPS; the VPS talks to Google. Local test: `python server.py --key X --port 8790`.

## History
HANDOFF.md is the original design record. Its §2 constraints and §3 architecture
remain valid; its Traditional-Chinese UI and multi-mode direction (translate /
lookup / event / reading / vocab...) was superseded 2026-07-08 — owner wants
English-only, Ask-only v1. Old mode prompts stay in HANDOFF.md §5 as reference.
