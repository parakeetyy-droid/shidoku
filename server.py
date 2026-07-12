#!/usr/bin/env python3
# Shidoku relay -- serves the app and streams /api/claude through Gemini's
# NATIVE endpoint with Google Search grounding enabled. The API key lives
# ONLY here, in an environment variable -- never in the browser.
#
# Wire protocol to the app (NDJSON, one JSON object per line):
#   {"t":"delta","text":"..."}            incremental answer text
#   {"t":"sources","items":[{title,url}]} web sources, when the model searched
#   {"t":"done"}                          end of answer
#   {"t":"error","message":"..."}         upstream/relay failure
#
# Run (VPS):    GEMINI_API_KEY=...  python3 server.py
# Run (local):  python3 server.py --key TEST --port 8790
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_BASE = os.environ.get("UPSTREAM", "https://generativelanguage.googleapis.com/v1beta")
BASE = os.path.dirname(os.path.abspath(__file__))


def arg(flag):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else None


MODEL = arg("--model") or os.environ.get("MODEL", "gemini-3.1-flash-lite")  # free-tier reliable/fast
KEY = arg("--key") or os.environ.get("GEMINI_API_KEY")
PORT = int(arg("--port") or os.environ.get("PORT", "8787"))
HOST = arg("--host") or os.environ.get("HOST", "127.0.0.1")  # 0.0.0.0 = reachable over LAN
TLS = arg("--tls")  # dir with cert.pem + key.pem -> serves HTTPS, plus http on PORT+1 for /ca.crt
if not KEY:
    sys.exit("Missing GEMINI_API_KEY")


def to_gemini(body):
    """Translate the app's vendor-neutral request body into native Gemini format."""
    contents = []
    for m in body.get("messages", []):
        role = "model" if m.get("role") == "assistant" else "user"
        parts = []
        c = m.get("content")
        if isinstance(c, list):
            for block in c:
                if block.get("type") == "text":
                    parts.append({"text": block["text"]})
                elif block.get("type") == "image":
                    src = block["source"]
                    parts.append({"inline_data": {
                        "mime_type": src["media_type"], "data": src["data"]}})
        else:
            parts.append({"text": c})
        contents.append({"role": role, "parts": parts})
    return {
        "contents": contents,
        "tools": [{"google_search": {}}],  # grounding: the model searches when facts/names matter
        "generationConfig": {"maxOutputTokens": body.get("max_tokens", 2000)},
    }


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

        def stream_upstream(payload):
            url = "%s/models/%s:streamGenerateContent?alt=sse" % (UPSTREAM_BASE, MODEL)
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json", "x-goog-api-key": KEY},
            )
            sources, seen = [], set()
            with urllib.request.urlopen(req, timeout=180) as resp:
                for raw in resp:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if not data or data == "[DONE]":
                        continue
                    chunk = json.loads(data)
                    for cand in chunk.get("candidates", []):
                        for part in cand.get("content", {}).get("parts", []):
                            if part.get("thought"):
                                continue  # internal reasoning of thinking models
                            if part.get("text"):
                                emit({"t": "delta", "text": part["text"]})
                        gm = cand.get("groundingMetadata") or {}
                        for gc in gm.get("groundingChunks", []):
                            web = gc.get("web") or {}
                            uri = web.get("uri")
                            if uri and uri not in seen:
                                seen.add(uri)
                                sources.append({"title": web.get("title") or uri, "url": uri})
            if sources:
                emit({"t": "sources", "items": sources[:6]})
            emit({"t": "done"})

        try:
            payload = to_gemini(body)
            try:
                stream_upstream(payload)
            except urllib.error.HTTPError as e:
                # Free-tier keys get 429 RESOURCE_EXHAUSTED on any google_search
                # request even when plain requests are fine (verified 2026-07-13).
                # The 429 arrives at open, before anything streamed to the app,
                # so retrying without the tool is safe. Ungrounded answers simply
                # carry no source chips; if Google grants grounding quota later,
                # answers upgrade automatically.
                if e.code == 429 and payload.pop("tools", None):
                    print("grounding quota exhausted -> answering ungrounded", flush=True)
                    stream_upstream(payload)
                else:
                    raise
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                err = json.loads(raw)
                if isinstance(err, list) and err:
                    err = err[0]  # Google wraps errors in a one-element array
                msg = err.get("error", {}).get("message") or raw[:300]
            except Exception:
                msg = raw[:300] or ("upstream HTTP %s" % e.code)
            try:
                emit({"t": "error", "message": msg})
            except Exception:
                pass
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            pass  # the app went away mid-stream; nothing to do
        except Exception as e:
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
    print("shidoku relay -> %s://%s:%d  (model: %s, grounded, streaming)" % (scheme, HOST, PORT, MODEL))
    httpd.serve_forever()
