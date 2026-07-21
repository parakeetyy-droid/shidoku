import Foundation

// ═══════════════ config — edit freely ═══════════════
// The relay is the PC on home Wi-Fi for now, the VPS later.
enum Config {
    // Two relays, routed PER ENDPOINT at launch (see RelayClient).
    //
    // LAN — the PC on home Wi-Fi: the fastest Ask at home. Its DHCP lease
    // drifts (.102 -> .103 -> .102), so the mDNS name PARAKEET.local (which
    // survives the drift) is tried FIRST, the last-known IP second.
    static let relayCandidates = [
        "http://PARAKEET.local:8790",
        "http://192.168.0.102:8790",
    ]
    // VPS — the public relay: it hosts frames Google can actually fetch (a LAN
    // frame URL is unreachable to Google), so Search routes here FIRST; it is
    // also the Ask fallback away from home. Raw IP over HTTP — see the ATS note
    // in project.yml.
    static let relayVPS = "http://67.230.168.215:8790"
    static let maxTokens = 4000
    // Frames are downscaled before upload — fewer vision tokens = faster
    // first word. Measured; don't raise without re-measuring.
    static let maxFrameSide: CGFloat = 1100

    // The model itself is chosen in server.py — this app is vendor-neutral.
    static let askPrompt = """
You are the engine behind a personal Visual Intelligence camera, built for an advanced English learner who wants to know what things are really called in American English.

Lead with the everyday American name of the main subject - the word a native speaker would actually say at home or in a store. Many everyday objects are called by a genericized brand name in America regardless of the actual brand; when such a name exists for this object, LEAD with it. If the everyday name and the precise name differ, give both.

Then, briefly:
- One or two natural collocations or verb pairings a native speaker would use with it.
- If there is text in the photo, transcribe the important part; translate non-English text into English.
- For posters, tickets, and labels: the key facts (what, when, where, how much).
- If identification is uncertain, say so and name the plausible alternatives.

Answer immediately from what you can see and already know - do not search the web to double-check things you can name confidently. Search only when you genuinely cannot identify the exact thing, or when the answer depends on current information (prices, availability, recent events). But if the user doubts or challenges a name you gave, verify it with a web search before answering - their doubt outranks your confidence.

Keep the whole answer compact - a few short lines. Go deeper only when asked a follow-up. English only. No greetings, no filler, no praise.
"""
}
// ════════════════════════════════════════════════════
