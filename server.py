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

TMP = os.path.join(BASE, "tmp")           # captured frames for the Read tool (gitignored)
SESSIONS = {}                             # image-hash -> claude session id (follow-ups resume)
CLAUDE_TIMEOUT = 240                      # hard kill for a wedged subprocess


def claude_cmd(extra):
    cmd = [CLAUDE_BIN, "-p", "--output-format", "stream-json",
           "--include-partial-messages", "--verbose",
           "--model", MODEL, "--allowedTools", "Read,WebSearch"]
    if os.name == "nt" and CLAUDE_BIN.lower().endswith((".cmd", ".bat")):
        cmd = ["cmd", "/c"] + cmd
    return cmd + extra


def msg_text(m):
    """The text of one vendor-neutral message (string or content blocks)."""
    c = m.get("content")
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if b.get("type") == "text")
    return c or ""


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

        proc = None
        try:
            msgs = body.get("messages", [])
            img_b64 = None
            if msgs and isinstance(msgs[0].get("content"), list):
                for b in msgs[0]["content"]:
                    if b.get("type") == "image":
                        img_b64 = b["source"]["data"]
            key = hashlib.sha256((img_b64 or "").encode()).hexdigest()[:16]
            sid = SESSIONS.get(key)

            if sid and len(msgs) > 1:
                prompt = msg_text(msgs[-1])          # follow-up: resume the same chat
                cmd = claude_cmd(["--resume", sid])
            else:
                prompt = msg_text(msgs[0]) if msgs else ""
                if len(msgs) > 1:                    # relay restarted mid-thread
                    prompt += "\n\nThe user's follow-up question: " + msg_text(msgs[-1])
                if img_b64:
                    os.makedirs(TMP, exist_ok=True)
                    img_path = os.path.join(TMP, "frame-%s.jpg" % key)
                    with open(img_path, "wb") as f:
                        f.write(base64.b64decode(img_b64))
                    prompt = ("First use the Read tool on the captured camera frame at "
                              "%s and look at it carefully. Then answer per the "
                              "instructions below.\n\n" % img_path) + prompt
                cmd = claude_cmd([])

            # scrub nested-session markers: the relay may itself have been
            # launched from inside a Claude Code session
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("CLAUDECODE", "CLAUDE_CODE_"))}
            proc = subprocess.Popen(cmd, cwd=BASE, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, encoding="utf-8", errors="replace", env=env)
            watchdog = threading.Timer(CLAUDE_TIMEOUT, proc.kill)
            watchdog.start()
            try:
                proc.stdin.write(prompt)
                proc.stdin.close()
                saw_partial = saw_text = failed = False
                for raw in proc.stdout:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        ev = json.loads(raw)
                    except ValueError:
                        continue
                    t = ev.get("type")
                    if t == "system" and ev.get("subtype") == "init" and ev.get("session_id"):
                        SESSIONS[key] = ev["session_id"]
                        while len(SESSIONS) > 40:
                            SESSIONS.pop(next(iter(SESSIONS)))
                    elif t == "stream_event":
                        e = ev.get("event") or {}
                        if e.get("type") == "content_block_delta":
                            d = e.get("delta") or {}
                            if d.get("type") == "text_delta" and d.get("text"):
                                saw_partial = saw_text = True
                                emit({"t": "delta", "text": d["text"]})
                    elif t == "assistant" and not saw_partial:
                        # this claude version didn't stream partials: emit whole blocks
                        for blk in (ev.get("message") or {}).get("content", []):
                            if blk.get("type") == "text" and blk.get("text"):
                                saw_text = True
                                emit({"t": "delta", "text": blk["text"]})
                    elif t == "result":
                        if ev.get("subtype") != "success" and not saw_text:
                            failed = True
                            emit({"t": "error", "message":
                                  str(ev.get("result") or ev.get("error") or ev.get("subtype"))[:300]})
                        elif not saw_text and ev.get("result"):
                            emit({"t": "delta", "text": ev["result"]})
                            saw_text = True
                        break
                rc = proc.wait(timeout=15)
                if not saw_text and not failed:
                    err = (proc.stderr.read() or "")[:300].strip()
                    failed = True
                    emit({"t": "error", "message":
                          "claude produced no answer (exit %s)%s" % (rc, (": " + err) if err else "")})
                if not failed:
                    emit({"t": "done"})
            finally:
                watchdog.cancel()
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            pass  # the app went away mid-stream; nothing to do
        except Exception as e:
            try:
                emit({"t": "error", "message": "relay: %s" % e})
            except Exception:
                pass
        finally:
            if proc and proc.poll() is None:
                proc.kill()


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
