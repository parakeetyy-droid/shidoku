import Foundation
import UIKit

// The client half of the brain wiring — unchanged protocol from the web era:
// POST {max_tokens, messages} to the relay, read NDJSON lines back:
//   {"t":"delta","text":...} {"t":"sources","items":[{title,url}]}
//   {"t":"done"} {"t":"error","message":...}
// Messages stay Anthropic-shaped (the relay translates); the image rides
// inline ONLY in the first user message. Errors after partial text keep the
// text and surface the cause, exactly like the old client.

struct SourceItem: Identifiable {
    let id = UUID()
    let title: String
    let url: String
}

struct RelayResult {
    let text: String
    let sources: [SourceItem]
    let softError: String?   // stream broke after partial text
}

enum RelayError: LocalizedError {
    case http(Int)
    case empty
    case stream(String)
    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .empty: return "The model returned no text."
        case .stream(let m): return m
        }
    }
}

enum RelayClient {

    // MARK: - address resolution (per endpoint, once per launch)

    // Two relays, routed per endpoint. Resolved ONCE at launch by probing every
    // candidate (LAN drifts with DHCP; the VPS is the public server) with a
    // cheap GET /. A `static let` Task runs the probes exactly once; concurrent
    // callers await the same result.
    //   ASK  (/api/claude): LAN first (fast at home), VPS last (the only answer
    //                       away from home).
    //   LENS (/api/lens):   VPS first, always — only a PUBLIC frame URL is
    //                       fetchable by Google, so a LAN frame is useless to
    //                       it. LAN is the fallback (the link still opens the
    //                       results page, just without the uploaded image).
    // If nothing is reachable, ASK falls back to the first LAN candidate and the
    // real request surfaces its own error, exactly as a bad address did before.
    private struct Routes {
        let ask: String
        let lens: String
        let lanFallback: String   // resolved LAN base, for the lens request-fallback
    }

    private static let resolution = Task<Routes, Never> { () -> Routes in
        // probe every host once, concurrently — each a cheap GET /
        let hosts = Config.relayCandidates + [Config.relayVPS]
        var reachable = Set<String>()
        await withTaskGroup(of: (String, Bool).self) { group in
            for h in hosts { group.addTask { (h, await probeReachable(h)) } }
            for await (h, ok) in group where ok { reachable.insert(h) }
        }
        let firstLAN = Config.relayCandidates.first ?? Config.relayVPS
        let lanBase = Config.relayCandidates.first(where: { reachable.contains($0) }) ?? firstLAN
        let lanUp = Config.relayCandidates.contains(where: { reachable.contains($0) })
        let vpsUp = reachable.contains(Config.relayVPS)
        return Routes(
            ask: lanUp ? lanBase : (vpsUp ? Config.relayVPS : firstLAN),
            lens: vpsUp ? Config.relayVPS : lanBase,
            lanFallback: lanBase
        )
    }

    /// Start resolving at launch so the routes are ready before the first Ask.
    static func warmUp() { _ = resolution }

    private static func routes() async -> Routes { await resolution.value }

    // Cheapest liveness probe the relay answers: a bare GET / returns 200
    // (server.py is a SimpleHTTPRequestHandler; the repo root has no index.html
    // so it serves a directory listing — no brain, no side effects). 3 s each;
    // all candidates are probed together at launch.
    private static func probeReachable(_ base: String) async -> Bool {
        guard let url = URL(string: base + "/") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // 3 s, not 2: PARAKEET.local resolves in ~2.3 s on this LAN (measured),
        // so a 2 s probe would always time out and hand the win to the drifty
        // IP. This lets the stable mDNS name win when it is up. Off the critical
        // path anyway (warmUp runs at launch).
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func imageBlock(base64 jpeg: String) -> [String: Any] {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg]
        ]
    }

    static func firstMessage(imageB64: String, extra: String?) -> [String: Any] {
        var text = Config.askPrompt
        if let extra = extra, !extra.isEmpty {
            text += "\n\nThe user also asks: " + extra
        }
        return [
            "role": "user",
            "content": [imageBlock(base64: imageB64), ["type": "text", "text": text]]
        ]
    }

    // Streams one exchange; onDelta receives the ACCUMULATED text each time.
    static func stream(messages: [[String: Any]],
                       onDelta: @escaping (String) -> Void) async throws -> RelayResult {
        guard let url = URL(string: await routes().ask + "/api/claude") else {
            throw RelayError.stream("bad relay URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "max_tokens": Config.maxTokens,
            "messages": messages
        ])
        req.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RelayError.http(http.statusCode)
        }

        var full = ""
        var sources: [SourceItem] = []
        var errMsg: String?

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["t"] as? String else { continue }
            switch t {
            case "delta":
                if let piece = obj["text"] as? String {
                    full += piece
                    let snapshot = full
                    await MainActor.run { onDelta(snapshot) }
                }
            case "sources":
                if let items = obj["items"] as? [[String: Any]] {
                    sources = items.map {
                        SourceItem(title: ($0["title"] as? String) ?? "source",
                                   url: ($0["url"] as? String) ?? "")
                    }
                }
            case "error":
                errMsg = (obj["message"] as? String) ?? "stream error"
            default:
                break // "done"
            }
        }

        let text = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let e = errMsg { throw RelayError.stream(e) }
            throw RelayError.empty
        }
        return RelayResult(text: text, sources: sources, softError: errMsg)
    }

    // POST the frozen frame to /api/lens; returns the Google Lens results URL.
    // Routes to the VPS first (only a PUBLIC frame URL is fetchable by Google);
    // on any failure there, falls back to the LAN base — that link still opens
    // the results page, just without the uploaded image (the old degraded
    // behavior, better than a dead button).
    static func lensURL(imageB64: String) async throws -> URL {
        let r = await routes()
        var bases = [r.lens]
        if r.lanFallback != r.lens { bases.append(r.lanFallback) }
        var lastError: Error = RelayError.stream("no lens route")
        for base in bases {
            do { return try await postLens(imageB64: imageB64, base: base) }
            catch { lastError = error }
        }
        throw lastError
    }

    private static func postLens(imageB64: String, base: String) async throws -> URL {
        guard let url = URL(string: base + "/api/lens") else {
            throw RelayError.stream("bad lens URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["image": imageB64])
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RelayError.http(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["url"] as? String, let result = URL(string: s) else {
            throw RelayError.stream("no result URL")
        }
        return result
    }

    // Downscale + encode a frame the way the web client did (1100 px cap).
    static func jpegBase64(from image: UIImage) -> String? {
        let w = image.size.width
        let h = image.size.height
        let scale = min(1.0, Config.maxFrameSide / max(w, h))
        let target = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: fmt)
        let small = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return small.jpegData(compressionQuality: 0.85)?.base64EncodedString()
    }
}
