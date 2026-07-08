#!/usr/bin/env python3
# Shidoku relay -- serves the app and forwards /api/claude to Gemini
# (via Google's OpenAI-compatible endpoint). The API key lives ONLY here,
# in an environment variable -- never in the browser.
#
# Run (VPS):    GEMINI_API_KEY=...  python3 server.py
# Run (local):  python3 server.py --key TEST --port 8790
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
MODEL = os.environ.get("MODEL", "gemini-3.5-flash")  # confirm the exact id in AI Studio
BASE = os.path.dirname(os.path.abspath(__file__))


def arg(flag):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else None


KEY = arg("--key") or os.environ.get("GEMINI_API_KEY")
PORT = int(arg("--port") or os.environ.get("PORT", "8787"))
if not KEY:
    sys.exit("Missing GEMINI_API_KEY")


def to_openai(body):
    """Translate the app's vendor-neutral request body into OpenAI chat format."""
    messages = []
    for m in body.get("messages", []):
        content = m.get("content")
        if isinstance(content, list):
            parts = []
            for block in content:
                if block.get("type") == "text":
                    parts.append({"type": "text", "text": block["text"]})
                elif block.get("type") == "image":
                    src = block["source"]
                    parts.append({"type": "image_url", "image_url": {
                        "url": "data:%s;base64,%s" % (src["media_type"], src["data"])}})
            content = parts
        messages.append({"role": m["role"], "content": content})
    return {"model": MODEL, "max_tokens": body.get("max_tokens", 2000), "messages": messages}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=BASE, **kw)

    def send_json(self, status, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/api/claude":
            self.send_json(404, {"error": {"message": "not found"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            req = urllib.request.Request(
                UPSTREAM,
                data=json.dumps(to_openai(body)).encode("utf-8"),
                headers={"Content-Type": "application/json",
                         "Authorization": "Bearer " + KEY},
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                upstream = json.load(resp)
            text = (upstream.get("choices") or [{}])[0].get("message", {}).get("content") or ""
            self.send_json(200, {"content": [{"type": "text", "text": text}]})
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                err = json.loads(raw)
                if isinstance(err, list) and err:
                    err = err[0]  # Google wraps errors in a one-element array
                msg = err.get("error", {}).get("message") or raw[:300]
            except Exception:
                msg = raw[:300] or ("upstream HTTP %s" % e.code)
            self.send_json(e.code, {"error": {"message": msg}})
        except Exception as e:
            self.send_json(502, {"error": {"message": "relay: %s" % e}})


if __name__ == "__main__":
    print("shidoku relay -> http://127.0.0.1:%d  (model: %s)" % (PORT, MODEL))
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
