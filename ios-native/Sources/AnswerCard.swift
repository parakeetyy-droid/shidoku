import SwiftUI

// The answer surface, cloned from the real VI recording (UI-ANALYSIS.md):
// a LIGHT blurred card pinned to the top — 12.5 pt side margins, 22 pt
// corners, near-black SF ~19 pt text, copy glyph top-right, provider
// attribution at the bottom. The photo below stays bright. One deliberate
// divergence, settled earlier: our text STREAMS into the card (VI shows a
// wall of text after long silence; ours starts in ~2 s).

struct ChatItem: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    var sources: [SourceItem] = []
    enum Role { case user, assistant }
}

private struct CardContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private let inkColor = Color.black.opacity(0.85)
private let claudeBrand = Color(red: 217.0/255.0, green: 119.0/255.0, blue: 87.0/255.0)

struct AnswerCard: View {
    let thread: [ChatItem]
    let loading: Bool
    let onCopyAll: () -> String

    @State private var contentHeight: CGFloat = 0
    @State private var appeared = false
    @State private var copied = false

    private var maxCardHeight: CGFloat {
        UIScreen.main.bounds.height * 0.62
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(thread) { item in
                        if item.role == .user {
                            userBubble(item.text)
                        } else if !item.text.isEmpty {
                            answerBlocks(item.text)
                            if !item.sources.isEmpty { sourceChips(item.sources) }
                        }
                    }
                    attribution
                    Color.clear.frame(height: 1).id("cardEnd")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: CardContentHeightKey.self, value: g.size.height)
                    }
                )
            }
            .onPreferenceChange(CardContentHeightKey.self) { contentHeight = $0 }
            .onChange(of: thread.last?.text ?? "") { _, _ in
                proxy.scrollTo("cardEnd", anchor: .bottom)
            }
        }
        .frame(height: min(max(contentHeight, 60), maxCardHeight))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) { copyButton }
        .environment(\.colorScheme, .light)
        .scaleEffect(appeared ? 1.0 : 0.92)
        .opacity(appeared ? 1.0 : 0.0)
        .blur(radius: appeared ? 0 : 6)
        .onAppear {
            if UIAccessibility.isReduceMotionEnabled {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                    appeared = true
                }
            }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = onCopyAll()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.45))
                .padding(14)
        }
        .buttonStyle(PressScaleStyle())
    }

    @ViewBuilder
    private func answerBlocks(_ text: String) -> some View {
        let blocks = Markdown.blocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .gap:
                    Color.clear.frame(height: 3)
                case .heading(let s):
                    Text(Markdown.inline(s))
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.black.opacity(0.5))
                        .padding(.top, 6)
                case .bullet(let marker, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(Color.black.opacity(0.4))
                        Text(Markdown.inline(s))
                    }
                    .font(.system(size: 19))
                    .foregroundStyle(inkColor)
                case .paragraph(let s):
                    Text(Markdown.inline(s))
                        .font(.system(size: 19))
                        .lineSpacing(5)
                        .foregroundStyle(inkColor)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(inkColor)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.top, 4)
    }

    private func sourceChips(_ sources: [SourceItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(sources) { s in
                    if let url = URL(string: s.url) {
                        Link(destination: url) {
                            Text(s.title.isEmpty ? "source" : s.title)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.black.opacity(0.55))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var attribution: some View {
        (Text("Claude").font(.system(size: 17, weight: .semibold)).foregroundColor(claudeBrand)
         + Text(" \u{2022} Check important info for mistakes.")
            .font(.system(size: 15))
            .foregroundColor(Color.black.opacity(0.4)))
            .padding(.top, 8)
    }
}
