import SwiftUI
import SafariServices

// The persistent post-capture row, cloned from the real VI recording:
// ONE light glass input capsule ("Ask about details…", provider mark
// inside-left) + a separate light glass ✕ disc at bottom-RIGHT. Visible in
// every frozen state. Also the top "Asking…" pill and the small error bar.

struct InputCapsuleRow: View {
    @Binding var text: String
    let loading: Bool
    let onSend: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: VI.capsuleSideMargin) {
            HStack(spacing: 10) {
                ClaudeMark(color: .black)
                    .frame(width: VI.markSize, height: VI.markSize)
                TextField("Ask about details\u{2026}", text: $text)
                    .font(.system(size: 17))
                    .foregroundStyle(VI.ink)
                    .tint(Color.black.opacity(0.6))
                    .submitLabel(.send)
                    .focused($focused)
                    .onSubmit { if !loading { onSend() } }
                    .disabled(loading)
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .frame(height: VI.capsuleHeight)
            .lightSurface(radius: VI.capsuleHeight / 2)

            Button(action: onClose) {
                // Demo-measured (demo_asking.png, 1pt=1px): on the 43 pt disc the
                // approved ✕ spans ~11 pt arm-to-arm at ~1.06 pt stroke (CSS spec:
                // 9.9 pt / 1.2 pt). SF xmark at 17 pt regular rendered ~13 pt / 1.58
                // pt — too big and too heavy (owner: "the ratio is off"). 14 pt light
                // lands ~10.7 pt arm / ~1.05 pt stroke: the demo's thin ✕.
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.black)
                    .frame(width: VI.closeDiscSize, height: VI.closeDiscSize)
                    .lightSurface(radius: VI.closeDiscSize / 2)
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, VI.capsuleSideMargin)
        .padding(.bottom, VI.rowBottomInset)
    }
}

// The pill wears the SAME surface as the card because they are one object —
// it expands in place into the card (frame-verified), so any difference in
// material would show as a flicker mid-morph.
struct AskingPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: VI.pillTextSize))
            .foregroundStyle(VI.pillInk)
            .frame(width: VI.pillWidth, height: VI.pillHeight)
            .lightSurface(radius: VI.pillRadius)
    }
}

struct ErrorBar: View {
    let message: String
    let onRetry: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Text("Error: " + message)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.88, green: 0.54, blue: 0.49))
                .lineLimit(3)
            if let onRetry = onRetry {
                Button("Retry", action: onRetry)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .glassEffect(.regular.interactive())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 11)
        .padding(.bottom, 4)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.65), in: Capsule())
    }
}

struct LensItem: Identifiable {
    let id = UUID()
    let url: URL
}

// Google results shown INSIDE the app (VI never leaves to a browser) —
// SFSafariViewController presented as a sheet.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
