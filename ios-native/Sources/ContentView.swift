import SwiftUI
import UIKit

// The whole app flow. States, cloned from the real VI recording:
//   live    — viewfinder + Ask/shutter/Search bar
//   frozen  — captured photo + persistent input capsule + ✕ (bar gone)
//   asking  — + light "Asking Claude…" pill top-center
//   answer  — + light card pinned to the top, streaming, photo stays bright
// Search opens Google results in an in-app sheet. The capture LIGHT is the
// settled native glow (GlowOverlay); the photo blur/brighten breath rides
// with it.

struct ContentView: View {
    @StateObject private var camera = CameraController()

    private enum Phase: Equatable { case live, frozen }
    @State private var phase = Phase.live

    @State private var frozenImage: UIImage?
    @State private var frozenB64: String?
    @State private var frozenBlur: CGFloat = 0
    @State private var frozenBright: Double = 0

    @State private var glow = GlowMode.idle
    @State private var bloomCount = 0

    @State private var thread: [ChatItem] = []
    @State private var messagesJSON: [[String: Any]] = []
    @State private var loading = false
    @State private var inputText = ""
    @State private var errorText: String?
    @State private var pendingRetry: (() -> Void)?

    @State private var lensItem: LensItem?
    @State private var toastText: String?

    // Bumped whenever the conversation is reset (capture / dismiss / unfreeze)
    // so a stream still in flight can never write into a newer capture.
    @State private var generation = 0
    @State private var controlsHidden = false
    // True through the dismissal cascade (card + capsule fade out, an empty
    // beat, then the bare bar fades in). Drives the opacity of both the card
    // and the bottom row so the three beats read the way the recording does.
    @State private var dismissing = false
    // When the last capture bloom started (nil under Reduce Motion / no bloom).
    // The Ask path reads it so the full ignite plays before the glow switches
    // to breathing, instead of the two states coalescing into one render.
    @State private var bloomStartedAt: Date?

    // The pill and the card are ONE object: frame analysis showed the pill
    // expanding in place into the card (~0.33 s, blur-to-sharp, no crossfade
    // and no gap). This namespace carries that geometry across the swap.
    @Namespace private var answerNS

    @Environment(\.scenePhase) private var scenePhase

    private var showCard: Bool {
        thread.contains { !$0.text.isEmpty }
    }
    private var showPill: Bool {
        loading && !showCard
    }
    /// A question is in play — the flow shows the input capsule + light ✕.
    /// Frozen WITHOUT one is the bare state: the Ask / ✕ / Search bar.
    private var askStarted: Bool {
        loading || !thread.isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if phase == .live {
                if let stand = previewPhoto {
                    // simulator screenshot run — no camera exists there
                    GeometryReader { geo in
                        Image(uiImage: stand)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                } else {
                    CameraPreview(session: camera.session).ignoresSafeArea()
                }
            }

            if let img = frozenImage {
                GeometryReader { geo in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: frozenBlur)
                        .brightness(frozenBright)
                }
                .ignoresSafeArea()
            }

            GlowOverlay(mode: glow, pinPeak: previewPinGlow)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if camera.denied && phase == .live {
                deniedOverlay
            }

            VStack(spacing: 0) {
                if showCard {
                    AnswerCard(thread: thread, loading: loading, onCopyAll: copyText)
                        .matchedGeometryEffect(id: "answerSurface", in: answerNS)
                        .padding(.horizontal, 12.5)
                        .padding(.top, 50)          // card top edge = 50 pt (measured)
                        .opacity(dismissing ? 0 : 1)
                } else if showPill {
                    AskingPill(text: "Asking Claude\u{2026}")
                        .matchedGeometryEffect(id: "answerSurface", in: answerNS)
                        .padding(.top, 48)          // pill top edge = 48 pt (measured)
                        // fade the pill IN (real VI ~0.27 s); on removal stay
                        // .identity so the pill→card morph is untouched
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                Spacer(minLength: 0)
            }
            // pin to the physical screen top: the 47 pt safe area was pushing
            // the pill to ~55 and the card to ~53; the spec is 48 / 50
            .ignoresSafeArea(.container, edges: .top)
            .animation(.smooth(duration: 0.34), value: showCard)   // pill→card morph (keep)
            .animation(.easeOut(duration: 0.27), value: showPill)  // pill fade-in (F2)

            if let toast = toastText {
                VStack {
                    Spacer()
                    Toast(text: toast).padding(.bottom, 140)
                }
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // VI fades the bar OUT while the capture light blooms, then fades
            // the post-capture controls in about 0.4 s after it settles. The
            // first build snapped straight from one bar to the other.
            bottomControls
                // controlsHidden: the capture-bloom hide. dismissing: the
                // cascade fade (its 0.2 s-out / 0.34 s-in timing comes from the
                // withAnimation calls in dismissAnswer, not from here).
                .opacity((controlsHidden || dismissing) ? 0 : 1)
                .allowsHitTesting(!dismissing)
                .animation(.easeInOut(duration: 0.28), value: controlsHidden)
        }
        .sheet(item: $lensItem) { item in
            // VI's Google sheet is draggable between a full detent (top ≈54 pt,
            // ~93% of the screen) and a low peek (top ≈743 pt, ~12%), both
            // measured from the recording.
            SafariSheet(url: item.url)
                .ignoresSafeArea()
                .presentationDetents([.large, .fraction(0.14)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(23)
        }
        .onAppear {
            if PreviewMode.active {
                if PreviewMode.sequence { runSequence() } else { setUpPreview() }
                return
            }
            camera.start()
            glow = .hello
            RelayClient.warmUp()   // resolve the relay address now, before the first Ask
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                if phase == .live { camera.start() }
            } else if newPhase == .background {
                camera.stop()
            }
        }
    }

    // MARK: - bottom controls

    @ViewBuilder
    private var bottomControls: some View {
        if phase == .live {
            if camera.denied {
                Color.clear.frame(height: 1)
            } else {
                BottomBar(centre: .shutter,
                          onAsk: askTapped, onCentre: shutterTapped, onSearch: searchTapped)
            }
        } else if !askStarted {
            // BARE FROZEN — the third bar mode, measured from the recording:
            // photo held, Ask / ✕ / Search. Ask starts the flow, ✕ goes live.
            BottomBar(centre: .close,
                      onAsk: { firstAsk(extra: nil) }, onCentre: unfreeze, onSearch: openLens)
        } else {
            VStack(spacing: 6) {
                if let err = errorText {
                    ErrorBar(message: err, onRetry: pendingRetry)
                }
                InputCapsuleRow(text: $inputText,
                                loading: loading,
                                onSend: sendFollowUp,
                                onClose: dismissAnswer)
            }
        }
    }

    private var deniedOverlay: some View {
        VStack(spacing: 14) {
            Text("Camera access is off.\nShidoku opens straight into a live viewfinder.")
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.60, green: 0.63, blue: 0.66))
                .multilineTextAlignment(.center)
                .lineSpacing(5)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive())
        }
        .padding(.horizontal, 44)
    }

    // MARK: - preview harness (simulator screenshots only)

    private var previewPhoto: UIImage? {
        PreviewMode.active ? PreviewMode.photo : nil
    }

    /// Freeze the glow at its ignite peak for the STILL capture screenshot
    /// only — never during the live sequence (which wants the real animation).
    private var previewPinGlow: Bool {
        PreviewMode.active && !PreviewMode.sequence && PreviewMode.state == "capture"
    }

    private func setUpPreview() {
        let photo = PreviewMode.photo
        switch PreviewMode.state {
        case "capture":
            frozenImage = photo; phase = .frozen
            bloomCount += 1; glow = .bloom(bloomCount)
            frozenBlur = 9; frozenBright = 0.16      // pinned at the bloom's peak
            controlsHidden = true                    // on-device the bar is hidden during the bloom
        case "asking":
            frozenImage = photo; phase = .frozen
            loading = true; glow = .think
        case "answer":
            frozenImage = photo; phase = .frozen
            thread = [ChatItem(role: .assistant, text: PreviewMode.cannedAnswer)]
        case "bare":
            frozenImage = photo; phase = .frozen
        default:
            phase = .live; glow = .idle
        }
    }

    // MARK: - preview motion sequence (CI video only)

    /// Drives the REAL state machine through the whole ask flow on a scripted
    /// timeline with a FAKE local stream — no network is ever touched. Runs
    /// only under `-shidokuPreview -shidokuSequence`; see PreviewMode.
    private func runSequence() {
        guard let photo = PreviewMode.photo else { return }
        phase = .live
        glow = .idle
        Task { @MainActor in
            // t≈1.0 s — the Ask tap. This is the REAL Ask path: beginFrozen
            // (photo bloom, glow .bloom, controls-hidden dance) then an
            // immediate ask start. Production paces bloom→think itself now
            // (F10, scheduleThinkingGlow), so there is NO manual hold — the full
            // ignite plays and hands off to breathing on its own. The bundled
            // still stands in for the camera frame.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            beginFrozen(image: photo, b64: "preview")
            thread.append(ChatItem(role: .assistant, text: ""))   // as firstAsk does
            loading = true                                         // the pill fades in
            scheduleThinkingGlow(gen: generation)                 // bloom → (~1.15 s) → think

            // ≈+1.5 s after the Ask tap — the fake stream (no network). The
            // first chunk flips showCard and triggers the pill→card morph, well
            // after the ignite has handed off to the breathing.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var acc = ""
            for piece in Self.chunk(PreviewMode.cannedAnswer, into: 10) {
                acc += piece
                updateLastAssistant(text: acc)
                try? await Task.sleep(nanoseconds: 60_000_000)     // ~60 ms / chunk
            }
            loading = false
            glow = .idle

            // hold ~2 s on the finished card, then the measured dismissal cascade
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            dismissAnswer()

            // hold ~1 s on the bare frozen photo (the cascade lands there), then
            // back to the live viewfinder
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            unfreeze()

            // W3 — a SECOND ignite in the same film, shutter-style (NO ask), so
            // the two capture choreographies can be compared frame-by-frame and
            // W1's per-capture randomness is visible. bloomCount is now 2, so
            // this ignite is seeded differently from the first. beginFrozen
            // alone plays the bloom and lands on the bare Ask/✕/Search bar.
            try? await Task.sleep(nanoseconds: 900_000_000)   // ≈t7.0 s: shutter tap
            beginFrozen(image: photo, b64: "preview")
            try? await Task.sleep(nanoseconds: 3_000_000_000) // ≈t10 s: hold on the bare bar
        }
    }

    /// Split a string into roughly `n` contiguous chunks for the fake stream.
    private static func chunk(_ s: String, into n: Int) -> [String] {
        guard n > 1, s.count > n else { return [s] }
        let chars = Array(s)
        let size = Int((Double(chars.count) / Double(n)).rounded(.up))
        var out: [String] = []
        var i = 0
        while i < chars.count {
            let end = min(i + size, chars.count)
            out.append(String(chars[i..<end]))
            i = end
        }
        return out
    }

    // MARK: - capture flow

    private func askTapped() {
        guard freeze() else { return }
        firstAsk(extra: nil)
    }

    private func shutterTapped() {
        _ = freeze()
    }

    private func searchTapped() {
        guard freeze() else { return }
        openLens()
    }

    @discardableResult
    private func freeze() -> Bool {
        guard phase == .live, !camera.denied else { return false }
        guard let img = camera.grabFrame(),
              let b64 = RelayClient.jpegBase64(from: img) else { return false }
        camera.stop()
        beginFrozen(image: img, b64: b64)
        return true
    }

    /// The shared freeze transition — the bloom, the glow, the reset and the
    /// controls-hidden dance. Live capture supplies the camera frame; the
    /// preview sequence supplies the bundled still (the simulator has no
    /// camera). Same animation code either way.
    private func beginFrozen(image: UIImage, b64: String) {
        generation += 1
        frozenImage = image
        frozenB64 = b64
        phase = .frozen
        thread = []
        messagesJSON = []
        errorText = nil
        pendingRetry = nil
        inputText = ""
        dismissing = false
        bloomCount += 1
        glow = .bloom(bloomCount)
        // stamp the ignite start so the Ask path (scheduleThinkingGlow) can let
        // it finish before breathing; nil under Reduce Motion (glow suppressed,
        // so no ignite to wait on — never a dead wait)
        bloomStartedAt = UIAccessibility.isReduceMotionEnabled ? nil : Date()
        runPhotoBloom()
        if !UIAccessibility.isReduceMotionEnabled {
            controlsHidden = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_050_000_000)   // the light settles
                controlsHidden = false
            }
        }
    }

    /// The measured dismissal cascade: the flow ✕ clears the card, capsule and
    /// ✕ together (~5 frames) and lands on the BARE frozen photo — it does NOT
    /// return to the camera. Only the centre ✕ there goes live again, and the
    /// card never comes back.
    private func dismissAnswer() {
        generation += 1
        // Beat 1 (~0.2 s): the card, the input capsule and the light ✕ fade out
        // TOGETHER. The data stays mounted so the capsule branch holds — without
        // this the bottom snapped straight to the bare bar. `dismissing` drives
        // the opacity of both the card and the bottom row.
        withAnimation(.easeOut(duration: 0.2)) { dismissing = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            // now tear the flow down — everything above is already invisible
            thread = []
            messagesJSON = []
            errorText = nil
            pendingRetry = nil
            inputText = ""
            loading = false
            glow = .idle
            // Beat 2 (~0.3 s): bare frozen photo, NO bottom controls.
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Beat 3 (~0.34 s): the Ask / ✕ / Search bar fades in.
            withAnimation(.easeInOut(duration: 0.34)) { dismissing = false }
        }
    }

    private func unfreeze() {
        generation += 1
        controlsHidden = false
        dismissing = false
        phase = .live
        frozenImage = nil
        frozenB64 = nil
        frozenBlur = 0
        frozenBright = 0
        thread = []
        messagesJSON = []
        errorText = nil
        pendingRetry = nil
        inputText = ""
        glow = .idle
        // no camera in the simulator/preview — the bundled still stands in for
        // the live viewfinder, so starting a session there only trips "denied"
        if !PreviewMode.active { camera.start() }
    }

    // the photo's blur+brighten breath during the capture light — part of the
    // settled wave motion (peaks ~230 ms in, settles crisp by ~1.05 s)
    private func runPhotoBloom() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        frozenBlur = 0
        frozenBright = 0
        withAnimation(.easeOut(duration: 0.23)) {
            frozenBlur = 9
            frozenBright = 0.16
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 230_000_000)
            withAnimation(.easeInOut(duration: 0.82)) {
                frozenBlur = 0
                frozenBright = 0
            }
        }
    }

    // MARK: - asking

    private func firstAsk(extra: String?) {
        guard let b64 = frozenB64 else { return }
        let first = [RelayClient.firstMessage(imageB64: b64, extra: extra)]
        thread.append(ChatItem(role: .assistant, text: ""))
        run(messages: first) { result in
            messagesJSON = first + [["role": "assistant", "content": result.text]]
        } onFail: {
            messagesJSON = []
            if thread.last?.role == .assistant, thread.last?.text.isEmpty == true {
                thread.removeLast()
            }
            pendingRetry = { retryFirstAsk(extra: extra) }
        }
    }

    private func retryFirstAsk(extra: String?) {
        errorText = nil
        pendingRetry = nil
        firstAsk(extra: extra)
    }

    private func sendFollowUp() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !loading, frozenB64 != nil else { return }
        inputText = ""
        thread.append(ChatItem(role: .user, text: t))
        if messagesJSON.isEmpty {
            // first ask failed earlier (or never ran): retry with the question attached
            firstAsk(extra: t)
            return
        }
        let msgs = messagesJSON + [["role": "user", "content": t]]
        thread.append(ChatItem(role: .assistant, text: ""))
        run(messages: msgs) { result in
            messagesJSON = msgs + [["role": "assistant", "content": result.text]]
        } onFail: {
            if thread.last?.role == .assistant, thread.last?.text.isEmpty == true {
                thread.removeLast()
            }
        }
    }

    private func run(messages: [[String: Any]],
                     onDone: @escaping (RelayResult) -> Void,
                     onFail: @escaping () -> Void) {
        loading = true
        errorText = nil
        pendingRetry = nil
        let gen = generation
        // was `glow = .think` — on the Ask path freeze() set glow = .bloom in
        // this SAME synchronous transaction, so .think overwrote it and the
        // ~1.15 s ignite never rendered. Hand the breathing off through the
        // pacer, which lets a fresh bloom play out first.
        scheduleThinkingGlow(gen: gen)
        Task { @MainActor in
            do {
                let result = try await RelayClient.stream(messages: messages) { accumulated in
                    guard gen == generation else { return }
                    updateLastAssistant(text: accumulated)
                }
                // the capture was dismissed or replaced while this was in
                // flight — drop it rather than writing into a newer thread
                guard gen == generation else { return }
                updateLastAssistant(text: result.text, sources: result.sources)
                if let soft = result.softError { errorText = soft }
                onDone(result)
            } catch {
                guard gen == generation else { return }
                errorText = error.localizedDescription
                onFail()
            }
            loading = false
            glow = .idle
        }
    }

    /// Move the glow to the thinking breathe. The Ask path just set glow =
    /// .bloom in the same transaction as the ask start, so switching to .think
    /// now would coalesce and skip the owner-settled ~1.15 s ignite. When a
    /// FRESH bloom is in flight, hand off on a LATER transaction so .bloom
    /// renders first; GlowMode's own `previous == .bloom` path then waits the
    /// ignite out (~1 s) before breathing — the demo's capture → ~1150 ms →
    /// thinking. Follow-ups and asks on an already-frozen photo have no fresh
    /// bloom, so they breathe at once. GlowOverlay itself is untouched.
    private func scheduleThinkingGlow(gen: Int) {
        guard let started = bloomStartedAt,
              Date().timeIntervalSince(started) < 0.4 else {
            glow = .think                       // no fresh capture light — breathe now
            return
        }
        bloomStartedAt = nil                    // consume this bloom
        Task { @MainActor in
            // let the .bloom transaction render (so apply(.bloom) actually runs)
            try? await Task.sleep(nanoseconds: 150_000_000)
            // a dismiss / unfreeze / new capture bumps generation; a finished or
            // failed request clears loading — either way, do NOT resurrect
            // .think (the glow must settle to .idle, never stick in .think).
            guard gen == generation, loading else { return }
            glow = .think
        }
    }

    private func updateLastAssistant(text: String, sources: [SourceItem]? = nil) {
        guard let idx = thread.lastIndex(where: { $0.role == .assistant }) else { return }
        thread[idx].text = text
        if let sources = sources { thread[idx].sources = sources }
    }

    private func copyText() -> String {
        thread.filter { $0.role == .assistant }.map { $0.text }.joined(separator: "\n\n")
    }

    // MARK: - search

    private func openLens() {
        guard let b64 = frozenB64 else { return }
        Task { @MainActor in
            do {
                let url = try await RelayClient.lensURL(imageB64: b64)
                lensItem = LensItem(url: url)
            } catch {
                showToast("Search failed: " + error.localizedDescription)
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.25)) { toastText = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
        }
    }
}
