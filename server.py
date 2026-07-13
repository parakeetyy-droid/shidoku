#!/usr/bin/env python3
# Shidoku relay -- serves the app; /api/claude streams answers from CLAUDE via
# a headless `claude -p` subprocess (the owner's Claude subscription -- no API
# key at all). The Kleenex problem (everyday American names, brand-generics)
# is covered by Claude's own WebSearch tool: the model verifies names on the
# web inside the same answer. Brain history: Claude API (v1 design) -> Gemini
# native+grounding (2026-07-11) -> claude -p headless (2026-07-13, owner:
# "don't want to bother with Gemini anymore").
#
# Wire protocol to the app (NDJSON, one JSON object per line):
#   {"t":"delta","text":"..."}            incremental answer text
#   {"t":"sources","items":[{title,url}]} web sources, when the model searched
#   {"t":"done"}                          end of answer
#   {"t":"error","message":"..."}         upstream/relay failure
#
# Run:  python3 server.py --port 8790          (claude CLI must be logged in)
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))


def arg(flag):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else None


MODEL = arg("--model") or os.environ.get("MODEL", "sonnet")  # fast; opus = richer, slower
PORT = int(arg("--port") or os.environ.get("PORT", "8787"))
HOST = arg("--host") or os.environ.get("HOST", "127.0.0.1")  # 0.0.0.0 = reachable over LAN
TLS = arg("--tls")  # dir with cert.pem + key.pem -> serves HTTPS, plus http on PORT+1 for /ca.crt
CLAUDE_BIN = arg("--claude") or os.environ.get("CLAUDE_BIN") or shutil.which("claude") or "claude"

CLAUDE_TIMEOUT = 240                      # hard kill for a wedged turn

# ── warm persistent claude processes ──
# Latency design: `claude -p --input-format stream-json` keeps ONE process per
# capture alive for the whole thread - the CLI boots once (and a spare is
# pre-booted in the pool before the user even taps), the image rides INLINE in
# the first message (no Read tool, no extra model turn), and follow-ups are
# just new stdin lines into the same process. First token ~2-4s vs ~8s for
# spawn-per-request with a Read roundtrip.

def spawn_claude():
    cmd = [CLAUDE_BIN, "-p", "--input-format", "stream-json",
           "--output-format", "stream-json", "--include-partial-messages",
           "--verbose", "--model", MODEL, "--allowedTools", "WebSearch",
           "--strict-mcp-config",  # no MCP servers: they only slow first init
           # replace Claude Code's huge default system prompt (~15k tokens of
           # tooling instructions): prefill is the bulk of first-token latency
           "--system-prompt",
           "You are the engine of Shidoku, a personal Visual Intelligence "
           "camera app. Answer exactly per the user's instructions, starting "
           "immediately from what you can see and already know. Use the "
           "WebSearch tool ONLY when you cannot confidently name what is in "
           "the photo, or when the answer depends on current information. "
           "Never search to double-check something you already know - EXCEPT "
           "when the user doubts or challenges a name you gave: then verify "
           "with a web search before answering."]
    if os.name == "nt" and CLAUDE_BIN.lower().endswith((".cmd", ".bat")):
        cmd = ["cmd", "/c"] + cmd
    env = {k: v for k, v in os.environ.items()          # scrub nested-session markers
           if not k.startswith(("CLAUDECODE", "CLAUDE_CODE_"))}
    env["MAX_THINKING_TOKENS"] = "0"  # extended thinking = 6+ silent seconds
    return subprocess.Popen(cmd, cwd=BASE, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, encoding="utf-8", errors="replace",
                            bufsize=1, env=env)


POOL = []                 # pre-booted AND primed spares
POOL_TARGET = 2           # 2 = a quick capture->retake->capture burst stays warm
THREADS = {}              # image-hash -> {proc, lock, ts}
_LOCK = threading.Lock()
LOG = os.path.join(BASE, "tmp", "relay.log")


def tlog(line):
    """Flight recorder: one line per Ask so 'it felt slow' is diagnosable."""
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 200_000:
            with open(LOG, encoding="utf-8", errors="replace") as f:
                tail = f.readlines()[-100:]
            with open(LOG, "w", encoding="utf-8") as f:
                f.writelines(tail)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%m-%d %H:%M:%S ") + line + "\n")
    except Exception:
        pass


def _top_up_pool():
    """Spawn a spare and run one throwaway turn through it: the CLI does its
    expensive init (config, session, API handshake) lazily on the FIRST
    message, so priming moves all of it off the user's first Ask."""
    try:
        p = spawn_claude()
        p.stdin.write(json.dumps({"type": "user", "message":
                                  {"role": "user", "content": "Reply with exactly: ok"}}) + "\n")
        p.stdin.flush()
        deadline = time.time() + 60
        for raw in p.stdout:
            if time.time() > deadline:
                break
            try:
                if json.loads(raw.strip() or "{}").get("type") == "result":
                    with _LOCK:
                        if len(POOL) < POOL_TARGET and p.poll() is None:
                            POOL.append(p)
                            return
                    break
            except ValueError:
                continue
        p.kill()
    except Exception:
        pass


def take_proc():
    with _LOCK:
        proc = POOL.pop() if POOL else None
    threading.Thread(target=_top_up_pool, daemon=True).start()
    if proc is not None and proc.poll() is None:
        return proc, "pool"
    return spawn_claude(), "cold"


def reaper():
    while True:
        time.sleep(60)
        now = time.time()
        with _LOCK:
            for k in [k for k, t in THREADS.items() if now - t["ts"] > 600]:
                t = THREADS.pop(k)
                try:
                    t["proc"].kill()
                except Exception:
                    pass


threading.Thread(target=reaper, daemon=True).start()
for _ in range(POOL_TARGET):  # pre-boot the spares
    threading.Thread(target=_top_up_pool, daemon=True).start()


def msg_text(m):
    """The text of one vendor-neutral message (string or content blocks)."""
    c = m.get("content")
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if b.get("type") == "text")
    return c or ""


def harvest(x, sources, seen):
    """Best-effort: collect {title,url} pairs from any nested tool-result shape.
    This CLI version returns WebSearch results as one STRING:
    'Web search results for query: ...\\n\\nLinks: [{"title":...,"url":...},...]'."""
    if isinstance(x, str):
        i = x.find("Links: [")
        if i >= 0:
            try:
                val, _ = json.JSONDecoder().raw_decode(x, i + 7)
                harvest(val, sources, seen)
            except ValueError:
                pass
        elif x.lstrip().startswith(("[", "{")):
            try:
                harvest(json.loads(x), sources, seen)
            except ValueError:
                pass
        return
    if isinstance(x, dict):
        u = x.get("url")
        if isinstance(u, str) and u.startswith("http") and u not in seen:
            seen.add(u)
            sources.append({"title": x.get("title") or u, "url": u})
        for v in x.values():
            harvest(v, sources, seen)
    elif isinstance(x, list):
        for v in x:
            harvest(v, sources, seen)


# Search: do NOT try uploading frames to Google's endpoints. Browsers get 403
# on lens.google.com/v3/upload AND /searchbyimage/upload; a server-side
# anonymous upload mints a results link the user's logged-in browser refuses
# ("image not associated with your account") - all verified 2026-07-13. The
# route that works is lens.google.com/uploadbyurl: GOOGLE fetches the frame
# from a public URL inside the user's own session. So the relay hosts each
# frame briefly; set PUBLIC_URL (or --public) to this server's public base
# once deployed - on a LAN address Google cannot reach the frame.
PUBLIC = arg("--public") or os.environ.get("PUBLIC_URL")
FRAMES = {}          # id -> (jpeg bytes, monotonic stamp)
FRAME_TTL = 600      # seconds a frame stays fetchable
FRAME_CAP = 30


def frame_put(jpeg):
    now = time.monotonic()
    for k in [k for k, (_, t) in FRAMES.items() if now - t > FRAME_TTL]:
        FRAMES.pop(k, None)
    while len(FRAMES) >= FRAME_CAP:
        FRAMES.pop(next(iter(FRAMES)), None)
    fid = uuid.uuid4().hex[:12]
    FRAMES[fid] = (jpeg, now)
    return fid


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=BASE, **kw)

    def end_headers(self):
        if self.path.split("?")[0].split("#")[0] in ("/", "/index.html"):
            self.send_header("Cache-Control", "no-cache")  # always revalidate the app shell
        super().end_headers()

    def do_GET(self):
        if self.path.startswith("/frame/"):  # short-lived frame hosting for uploadbyurl
            item = FRAMES.get(self.path[len("/frame/"):].split(".")[0])
            if not item:
                self.send_json(404, {"error": {"message": "frame expired"}})
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(item[0])))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(item[0])
            return
        if TLS and self.path == "/ca.crt":  # let the iPhone download the cert to trust
            with open(os.path.join(TLS, "cert.pem"), "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-x509-ca-cert")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()

    def send_json(self, status, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path == "/api/lens":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length))
                fid = frame_put(base64.b64decode(body["image"]))
                base = (PUBLIC or "%s://%s" % ("https" if TLS else "http",
                        self.headers.get("Host") or "%s:%s" % (HOST, PORT))).rstrip("/")
                frame_url = "%s/frame/%s.jpg" % (base, fid)
                self.send_json(200, {"url":
                    "https://lens.google.com/uploadbyurl?url=" + urllib.parse.quote(frame_url, safe="")})
            except Exception as e:
                self.send_json(502, {"error": {"message": "lens: %s" % e}})
            return
        if self.path != "/api/claude":
            self.send_json(404, {"error": {"message": "not found"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
        except Exception as e:
            self.send_json(400, {"error": {"message": "bad request: %s" % e}})
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def emit(obj):
            self.wfile.write((json.dumps(obj) + "\n").encode("utf-8"))
            self.wfile.flush()

        entry = None
        t0 = time.time()
        t_first = src_kind = None
        try:
            msgs = body.get("messages", [])
            img_b64 = ""
            if msgs and isinstance(msgs[0].get("content"), list):
                for b in msgs[0]["content"]:
                    if b.get("type") == "image":
                        img_b64 = b["source"]["data"]
            key = hashlib.sha256(img_b64.encode()).hexdigest()[:16]

            with _LOCK:
                entry = THREADS.get(key)
                if entry and entry["proc"].poll() is not None:
                    THREADS.pop(key, None)
                    entry = None
            if entry and len(msgs) > 1:
                message = msgs[-1]                    # follow-up into the live process
                src_kind = "resume"
            else:
                message = msgs[0] if msgs else {"role": "user", "content": ""}
                if len(msgs) > 1:                     # thread lost (relay/proc restart): rebuild
                    story = "\n\n".join(
                        ("You answered earlier:\n" if m.get("role") == "assistant"
                         else "The user then asked:\n") + msg_text(m) for m in msgs[1:])
                    message = {"role": "user", "content":
                               list(msgs[0]["content"]) + [{"type": "text", "text": story}]
                               if isinstance(msgs[0].get("content"), list)
                               else msg_text(msgs[0]) + "\n\n" + story}
                proc, src_kind = take_proc()
                entry = {"proc": proc, "lock": threading.Lock(), "ts": time.time()}
                with _LOCK:
                    old = THREADS.get(key)
                    if old:
                        try:
                            old["proc"].kill()
                        except Exception:
                            pass
                    THREADS[key] = entry
                    while len(THREADS) > 4:           # each live process holds real RAM
                        victim = THREADS.pop(next(iter(THREADS)))
                        try:
                            victim["proc"].kill()
                        except Exception:
                            pass

            with entry["lock"]:
                entry["ts"] = time.time()
                proc = entry["proc"]
                watchdog = threading.Timer(CLAUDE_TIMEOUT, proc.kill)
                watchdog.start()
                try:
                    proc.stdin.write(json.dumps({"type": "user", "message": message}) + "\n")
                    proc.stdin.flush()
                    saw_partial = saw_text = failed = False
                    sources, seen = [], set()
                    for raw in proc.stdout:
                        raw = raw.strip()
                        if not raw:
                            continue
                        try:
                            ev = json.loads(raw)
                        except ValueError:
                            continue
                        t = ev.get("type")
                        if t == "stream_event":
                            e = ev.get("event") or {}
                            if e.get("type") == "content_block_delta":
                                d = e.get("delta") or {}
                                if d.get("type") == "text_delta" and d.get("text"):
                                    saw_partial = saw_text = True
                                    t_first = t_first or time.time()
                                    emit({"t": "delta", "text": d["text"]})
                        elif t == "assistant":
                            for blk in (ev.get("message") or {}).get("content", []):
                                if blk.get("type") == "text" and blk.get("text") and not saw_partial:
                                    saw_text = True
                                    t_first = t_first or time.time()
                                    emit({"t": "delta", "text": blk["text"]})
                            harvest((ev.get("message") or {}).get("content"), sources, seen)
                        elif t == "user":
                            # web-search results ride back as tool_result blocks
                            harvest((ev.get("message") or {}).get("content"), sources, seen)
                        elif t == "result":
                            if ev.get("subtype") != "success" and not saw_text:
                                failed = True
                                emit({"t": "error", "message":
                                      str(ev.get("result") or ev.get("error") or ev.get("subtype"))[:300]})
                            elif not saw_text and ev.get("result"):
                                t_first = t_first or time.time()
                                emit({"t": "delta", "text": ev["result"]})
                                saw_text = True
                            break
                    else:  # stdout EOF: the process died mid-turn
                        if not saw_text:
                            failed = True
                            emit({"t": "error", "message": "the brain restarted - ask again"})
                        with _LOCK:
                            THREADS.pop(key, None)
                    entry["ts"] = time.time()
                    if not failed:
                        if sources:
                            emit({"t": "sources", "items": sources[:6]})
                        emit({"t": "done"})
                    tlog("%s %-6s first=%s done=%.1fs chips=%d%s" % (
                        key[:8], src_kind or "?",
                        ("%.1fs" % (t_first - t0)) if t_first else "-",
                        time.time() - t0, len(sources), " ERROR" if failed else ""))
                finally:
                    watchdog.cancel()
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            # the app went away mid-stream: kill the proc so its stdout can't
            # jam a future turn with half-consumed events
            if entry:
                try:
                    entry["proc"].kill()
                except Exception:
                    pass
                with _LOCK:
                    THREADS.pop(key, None)
        except Exception as e:
            tlog("request failed after %.1fs: %s" % (time.time() - t0, e))
            try:
                emit({"t": "error", "message": "relay: %s" % e})
            except Exception:
                pass


if __name__ == "__main__":
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    scheme = "http"
    if TLS:
        import ssl
        import threading
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.path.join(TLS, "cert.pem"), os.path.join(TLS, "key.pem"))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
        helper = ThreadingHTTPServer((HOST, PORT + 1), Handler)  # plain-http side door for /ca.crt
        threading.Thread(target=helper.serve_forever, daemon=True).start()
        print("cert for the phone -> http://%s:%d/ca.crt" % (HOST, PORT + 1))
    print("shidoku relay -> %s://%s:%d  (brain: claude -p, model %s, web search on)" % (scheme, HOST, PORT, MODEL))
    httpd.serve_forever()
