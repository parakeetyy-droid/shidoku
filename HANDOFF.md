> **STATUS 2026-07-08 — partially superseded.** The owner redirected v1:
> **English only** (zero Chinese/Japanese in UI, prompts, and responses), a
> **single feature** — the Ask button, cloning Apple Visual Intelligence's
> camera UI (Ask / shutter / Search) with Claude as the model behind Ask —
> and Search left as a stub. The §2 empirical constraints and §3 architecture
> below remain authoritative. §4 (mode table) and §5 (bilingual source) are
> **historical**: kept only as reference for possible future mode packs.
> Current truth lives in `CLAUDE.md` and the actual `index.html` / `server.js`.

---

# HANDOFF — 視読 SHIDOKU (English-learning visual intelligence PWA)
You are Claude Code, picking up a project designed and partially built in claude.ai.
This file is the complete transfer of context. Trust it: the constraints below were
established **empirically**, not guessed. Do not re-litigate them.
---
## 1. What this is
A camera-first iPhone PWA — a personal, upgraded clone of Apple's Visual
Intelligence — whose analysis brain is the Anthropic API. The owner is a native
Mandarin speaker (Traditional-Chinese-preferring), an advanced English learner
whose study practice centers on literary close reading (Hawthorne, Austen, Donne,
Hardy), naturalizing their own English prose toward native American English, and
etymology-grounded vocabulary acquisition. **The study modes target English
learning, not Japanese.** (An earlier iteration had Japanese modes; that mode
pack lives in chat history and may return later as a swappable pack.)
Core requirement, verbatim from the owner: *the app must open already in the
camera.* Tap the home-screen icon → live viewfinder, zero taps.
## 2. Hard-won constraints (empirical — do not rediscover)
- **Claude.ai artifacts cannot do this app.** Tested on-device: the artifact
  iframe's permissions policy denies `getUserMedia` with `NotAllowedError`
  ("not allowed by the user agent or the platform in the current context")
  even though `window.isSecureContext`, `mediaDevices`, and `getUserMedia`
  all exist. iOS never even shows a permission prompt. Hence: PWA on own VPS.
- **No web page can open the system camera without a user gesture** (WebKit
  rule for file inputs). The zero-tap requirement therefore *requires* live
  `getUserMedia`, which requires a secure context (HTTPS) outside the artifact.
- `<input type="file" accept="image/*" capture="environment">` on iOS skips the
  Take Photo / Library chooser and opens the rear camera directly — kept as the
  fallback path if `getUserMedia` is ever denied.
- Home-screen (standalone) PWAs support `getUserMedia` on modern iOS; after the
  user taps Allow once, the installed app remembers. On `visibilitychange` the
  stream dies in the background — must stop on hidden and restart on visible.
- iPhone photo picker returns HEIC; decoding via `<img>` → canvas → JPEG
  normalizes it (Safari decodes HEIC natively). Always route through canvas.
- `<video>` needs `playsinline muted autoplay` on iOS.
- Layout must respect `env(safe-area-inset-*)`; viewport uses `viewport-fit=cover`.
- The owner is in mainland China. The VPS is the network egress: the phone talks
  only to the VPS domain; the relay talks to api.anthropic.com. This solves
  CORS, key secrecy, and reachability in one stroke. **Never put the API key
  in client code.**
- API billing is separate from the owner's Claude subscription (pay-as-you-go;
  a few US cents per analysis).
## 3. Architecture
```
iPhone (home-screen PWA, vanilla JS, one file)
   │  same-origin POST /api/claude   { model, max_tokens, messages, [tools] }
   ▼
VPS: node server.js  (static files + relay; key in env var)
   │  x-api-key, anthropic-version: 2023-06-01
   ▼
api.anthropic.com /v1/messages   (model: see index.html config;
                                  lookup mode adds web_search tool)
Caddy in front for HTTPS (camera requires secure context).
```
Response contract: concatenate all `content` blocks of `type === "text"`
(web-search responses interleave `server_tool_use` blocks — ignore them).
Multi-turn: full `messages` history is resent each call; the image rides only
in the first user message.
## 4. Mode specification (HISTORICAL — superseded by Ask-only v1)
Two chip rows. **General** = Apple Visual Intelligence parity (answers in
Traditional Chinese). **學習** = English-learning pipelines (answers in English —
the owner thinks and writes in English; immersion is intentional). All modes:
mechanism-first explanation, no filler praise, no flattery.
| id | label | behavior |
|---|---|---|
| auto | 智慧 | classify frame content (object/text/poster/landmark) and respond appropriately; 繁中 |
| translate | 翻譯 | transcribe all text, faithful 繁中 translation, note untranslatables; 繁中 |
| lookup | 查詢 | identify subject, then **live web search** for hours/prices/reviews/status; 繁中 |
| event | 事件 | extract 標題/日期/開始時間/結束時間/地點/備註 card (labels must stay exactly these — the .ics parser regexes depend on them); client builds downloadable .ics |
| ask | 詢問 | free-form Q&A about the photo |
| reading | 精讀 | English literary close reading: transcribe; per sentence — named syntax parse, vocabulary gloss w/ etymology + register + period usage, devices and allusions (biblical/classical) with sources, plain-English paraphrase; closing note on what a Chinese translation would lose |
| naturalize | 潤色 | the owner's own English writing: transcribe; quote each ESL-ish segment (grammatical but unnatural for a native American English speaker), give a natural equivalent preserving feeling and register, explain the mechanism (collocation, article logic, adverb placement, register mismatch, L1 interference); end with a fully naturalized version that preserves the writer's voice; mark illegible handwriting [?] |
| vocab | 語彙 | harvest genuinely acquisition-worthy words: in-context meaning + 繁中 anchor gloss, etymology, register, two collocations, one native example sentence; flag words used differently from their common modern sense; order by usefulness |
The exact bilingual prompt strings from the earlier iteration lived in the
original §5 source (see chat history). If a mode pack returns, rewrite the
prompts to the owner's current rule: **English only for English-learning
tools** — no Chinese glosses in UI or responses.
## 5. Source (HISTORICAL)
The original bilingual single-file app (mode chips, 事件 .ics export, question
input, 相簿 library button) was materialized from chat history and then
**replaced 2026-07-08** by the current Ask-only `index.html`. If you need the
old source, it is in the claude.ai chat history; do not resurrect it into this
repo without the owner asking.
Repo layout (current):
```
shidoku/
├── index.html      ← full app (Ask-only, English-only)
├── server.js       ← relay + static server
├── CLAUDE.md       ← invariants for future sessions (authoritative)
├── HANDOFF.md      ← this file (historical design record)
└── Caddyfile.example
```
## 6. Deployment (owner's environment)
1. `console.anthropic.com` → create API key (billing is pay-as-you-go, separate
   from the Claude subscription; a few cents per analysis).
2. Copy the repo to the VPS. `ANTHROPIC_API_KEY=sk-ant-... node server.js`
   (long-run with pm2 or a systemd unit carrying the env var).
3. Caddy (or nginx+certbot) in front for HTTPS — the camera requires a secure
   context, this is not optional.
4. iPhone Safari → open the URL → Allow camera → Share → Add to Home Screen.
   Launch from the icon: live viewfinder, zero taps.
## 7. Original tasks (COMPLETED 2026-07-08, with owner's revised scope)
1. ~~Materialize the repo~~ — done, but per the owner's revision: English-only,
   Ask-only, Apple-VI-parity UI (Ask / shutter / Search), Search stubbed.
2. ~~Write a slim CLAUDE.md~~ — done.
3. ~~Sanity checks~~ — index.html verified in a local preview browser with
   mocked camera + relay. server.js could not be runtime-checked on the owner's
   Windows box (no Node.js) — it is a near-verbatim copy of the tested handoff
   version; first `node server.js` on the VPS is the real check.
4. Handed back for deployment.
## 8. Roadmap (only when the owner asks)
- Streaming responses (SSE pass-through in the relay) for long analyses.
- Session history via localStorage (allowed in a real browser, unlike artifacts).
- `icon.png` + minimal `manifest.json` for a proper home-screen icon.
- Google Lens hand-off behind the Search button (currently a stub).
- English-learning mode packs (close reading, naturalize, vocab harvest) as a
  swappable prompt set — English-only per the owner's rule.
- Back Tap → Shortcut → open PWA, for a hardware-button feel.
