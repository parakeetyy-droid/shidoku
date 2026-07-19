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

            GlowOverlay(mode: glow)
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
                        .padding(.top, 6)
                } else if showPill {
                    AskingPill(text: "Asking Claude\u{2026}")
                        .matchedGeometryEffect(id: "answerSurface", in: answerNS)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .animation(.smooth(duration: 0.34), value: showCard)

            if let toast = toastText {
                VStack {
                    Spacer()
                    Toast(text: toast).padding(.bottom, 140)
                }
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomControls }
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
            if PreviewMode.active { setUpPreview(); return }
            camera.start()
            glow = .hello
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

    private func setUpPreview() {
        let photo = PreviewMode.photo
        switch PreviewMode.state {
        case "capture":
            frozenImage = photo; phase = .frozen
            bloomCount += 1; glow = .bloom(bloomCount)
            frozenBlur = 9; frozenBright = 0.16      // pinned at the bloom's peak
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
        generation += 1
        frozenImage = img
        frozenB64 = b64
        phase = .frozen
        camera.stop()
        thread = []
        messagesJSON = []
        errorText = nil
        pendingRetry = nil
        inputText = ""
        bloomCount += 1
        glow = .bloom(bloomCount)
        runPhotoBloom()
        return true
    }

    /// The measured dismissal cascade: the flow ✕ clears the card, capsule and
    /// ✕ together (~5 frames) and lands on the BARE frozen photo — it does NOT
    /// return to the camera. Only the centre ✕ there goes live again, and the
    /// card never comes back.
    private func dismissAnswer() {
        generation += 1
        withAnimation(.easeOut(duration: 0.2)) {
            thread = []
        }
        messagesJSON = []
        errorText = nil
        pendingRetry = nil
        inputText = ""
        loading = false
        glow = .idle
    }

    private func unfreeze() {
        generation += 1
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
        camera.start()
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
        glow = .think
        let gen = generation
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
