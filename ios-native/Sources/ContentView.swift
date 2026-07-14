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

    @Environment(\.scenePhase) private var scenePhase

    private var showCard: Bool {
        thread.contains { !$0.text.isEmpty }
    }
    private var showPill: Bool {
        loading && !showCard
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if phase == .live {
                CameraPreview(session: camera.session).ignoresSafeArea()
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
                        .padding(.horizontal, 12.5)
                        .padding(.top, 6)
                } else if showPill {
                    AskingPill(text: "Asking Claude\u{2026}")
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }

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
            SafariSheet(url: item.url).ignoresSafeArea()
        }
        .onAppear {
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
                BottomBar(onAsk: askTapped, onShutter: shutterTapped, onSearch: searchTapped)
            }
        } else {
            VStack(spacing: 6) {
                if let err = errorText {
                    ErrorBar(message: err, onRetry: pendingRetry)
                }
                InputCapsuleRow(text: $inputText,
                                loading: loading,
                                onSend: sendFollowUp,
                                onClose: unfreeze)
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

    private func unfreeze() {
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
        Task { @MainActor in
            do {
                let result = try await RelayClient.stream(messages: messages) { accumulated in
                    updateLastAssistant(text: accumulated)
                }
                updateLastAssistant(text: result.text, sources: result.sources)
                if let soft = result.softError { errorText = soft }
                onDone(result)
            } catch {
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
