import SwiftUI

// The same line-level markdown the web client rendered: #### headings,
// -/• bullets, 1./1) numbered items, blank-line gaps, **bold** / *italic*
// inline. Kept deliberately small — answers are compact by prompt design.

enum MDBlock {
    case heading(String)
    case bullet(marker: String, text: String)
    case paragraph(String)
    case gap
}

enum Markdown {

    static func blocks(_ text: String) -> [MDBlock] {
        text.components(separatedBy: "\n").map { line -> MDBlock in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .gap }
            if let r = t.range(of: "^#{1,4}\\s+", options: .regularExpression) {
                return .heading(String(t[r.upperBound...]))
            }
            if let r = t.range(of: "^[-•]\\s+", options: .regularExpression) {
                return .bullet(marker: "\u{00B7}", text: String(t[r.upperBound...]))
            }
            if let r = t.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
                let marker = String(t[t.startIndex..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                return .bullet(marker: marker, text: String(t[r.upperBound...]))
            }
            return .paragraph(t)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
