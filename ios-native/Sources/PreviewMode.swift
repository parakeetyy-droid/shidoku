import SwiftUI
import UIKit

// Screenshot harness. There is no Mac, simulator or device on the owner's
// side of this project, so every UI change used to be written blind and
// judged only after he sideloaded it. This lets the CI runner boot a
// simulator, force each UI state, and upload real screenshots — the same
// see-it-then-fix-it loop the HTML demo gives, but for the actual app.
//
//   Shidoku.app -shidokuPreview -shidokuState answer
//
// The camera does not exist in the simulator, so a bundled still stands in
// for the viewfinder. Nothing here runs unless -shidokuPreview is passed.

enum PreviewMode {
    static let active: Bool =
        ProcessInfo.processInfo.arguments.contains("-shidokuPreview")

    /// live | capture | asking | answer | bare
    static var state: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-shidokuState"), i + 1 < args.count else { return "live" }
        return args[i + 1]
    }

    static var photo: UIImage? {
        UIImage(named: "PreviewPhoto")
    }

    // A canned answer in the real ASK_PROMPT voice, long enough to exercise
    // wrapping, the attribution row and the card's height behaviour.
    static let cannedAnswer = """
    Plushie — most Americans would just say a stuffed animal; a small clip-on \
    one like this is a plush charm or keychain plush.

    Collocations: clip a plushie onto your backpack · a plush keychain.

    It's holding an orange maple leaf, with a knit scarf around its neck.
    """
}
