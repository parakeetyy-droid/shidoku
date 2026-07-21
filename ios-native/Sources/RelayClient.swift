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

    // MARK: - address resolution (drift-proof, once per launch)

    // The relay's LAN IP drifts with DHCP (.102 -> .103 -> .102), so we probe
    // an ordered candidate list (mDNS name first, last-known IP second) ONCE at
    // launch and use the winner for both endpoints. A `static let` Task runs
    // the probes exactly once; concurrent callers await the same result. If
    // every probe fails we fall back to the first candidate and let the real
    // request surface its own error, exactly as a bad address did before.
    private static let resolution = Task<String, Never> { () -> String in
        for base in Config.relayCandidates {
            if await probeReachable(base) { return base }
        }
        return Config.relayCandidates.first ?? "http://PARAKEET.local:8790"
    }

    /// Start resolving at launch so the winner is ready before the first Ask.
    static func warmUp() { _ = resolution }

    private static func resolvedBase() async -> String { await resolution.value }

    // Cheapest liveness probe the relay answers: a bare GET / returns 200
    // (server.py is a SimpleHTTPRequestHandler; the repo root has no index.html
    // so it serves a directory listing — no brain, no side effects). ~2 s, then
    // the next candidate.
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
        guard let url = URL(string: await resolvedBase() + "/api/claude") else {
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
    static func lensURL(imageB64: String) async throws -> URL {
        guard let url = URL(string: await resolvedBase() + "/api/lens") else {
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
