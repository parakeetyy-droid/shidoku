// Shidoku relay — serves index.html and forwards /api/claude to Anthropic.
// The API key lives ONLY here (environment variable), never in the browser.
// Run:  ANTHROPIC_API_KEY=sk-ant-...  node server.js
const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");
const KEY = process.env.ANTHROPIC_API_KEY;
const PORT = process.env.PORT || 8787;
if (!KEY) { console.error("Missing ANTHROPIC_API_KEY"); process.exit(1); }
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".json": "application/json",
};
http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/api/claude") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const fwd = https.request(
        {
          hostname: "api.anthropic.com",
          path: "/v1/messages",
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-api-key": KEY,
            "anthropic-version": "2023-06-01",
          },
        },
        (ar) => {
          res.writeHead(ar.statusCode, { "content-type": "application/json" });
          ar.pipe(res);
        }
      );
      fwd.on("error", (e) => {
        res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: "relay: " + e.message } }));
      });
      fwd.end(body);
    });
    return;
  }
  let p = decodeURIComponent(req.url.split("?")[0]);
  if (p === "/") p = "/index.html";
  if (p.includes("..")) { res.writeHead(403); res.end(); return; }
  const file = path.join(__dirname, p);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "content-type": MIME[path.extname(file)] || "application/octet-stream" });
    res.end(data);
  });
}).listen(PORT, "127.0.0.1", () => console.log("shidoku relay -> http://127.0.0.1:" + PORT));
