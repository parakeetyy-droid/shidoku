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
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.black.opacity(0.8))
                TextField("Ask about details\u{2026}", text: $text)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .tint(Color.black.opacity(0.6))
                    .submitLabel(.send)
                    .focused($focused)
                    .onSubmit { if !loading { onSend() } }
                    .disabled(loading)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .glassEffect()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressScaleStyle())
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .environment(\.colorScheme, .light)
        .padding(.horizontal, 11)
        .padding(.bottom, 6)
    }
}

struct AskingPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color(red: 0.28, green: 0.28, blue: 0.30))
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .glassEffect()
            .environment(\.colorScheme, .light)
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
