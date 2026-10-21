import Foundation

/// One of the speedrun.com Minecraft: Java Edition remap rules the checker cites (spec 5.5.4), quoted from
/// rules v8 (`Minecraft-Java-Edition-Speedrunning/rules`, `rules.typ`, commit 6cff8ae, Oct 17 2026).
/// A.10.1–A.10.4 read the same in v7.
public struct SpeedrunRule: Hashable, Sendable {
    public let number: String
    public let title: String
    /// The rule's own words, one line per numbered item.
    public let quote: [String]

    public static let rulesVersion = "v8"
    public static let rulesURL = URL(string: "https://www.minecraftspeedrunning.com/public-resources/rules")!

    public static let oneKeyOneInput = SpeedrunRule(number: "A.10.1", title: "One key, one input", quote: [
        "A.10.1) You may remap keys using external programs, but each game input may have only one key, and each key may cause only one game input.",
        "A.10.1.a) Example: Shift+F3 cannot be rebound to a singular key.",
    ])

    public static let buttonsOnly = SpeedrunRule(number: "A.10.2", title: "Buttons only", quote: [
        "A.10.2) If keys are rebound, they must be to buttons. This excludes but is not limited to:",
        "A.10.2.a) Remapping to a scroll-wheel",
    ])

    public static let noRepeatAbuse = SpeedrunRule(number: "A.10.3", title: "No repeat abuse", quote: [
        "A.10.3) You must not rebind the \u{201C}Attack/Destroy\u{201D} or \u{201C}Use Item/Place Block\u{201D} functions to a keyboard button to abuse repeated inputs.",
    ])

    public static let noMacros = SpeedrunRule(number: "A.10.4", title: "No macros", quote: [
        "A.10.4) Macros are not allowed to be triggered during a run.",
        "A.10.4.a) Exception: Macros may resize the game window to an unlimited number of resolutions if the game window stays within monitor bounds.",
        "A.10.4.b) Exception: Macros may resize the game window to one resolution outside the monitor bounds, up to a maximum of 16384 pixels in width or height.",
        "A.10.4.c) Clarification: There are no restrictions on when resize macros may be used during the run.",
        "A.10.4.d) Exception: Toggle sprint macros are allowed in all versions.",
    ])
}

/// One problem the conflict & rule checker found. Advisory only: it never blocks a save.
public struct CheckerFinding: Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case duplicateRebind, shadowedRule, chainedRebind
        case oneKeyOneInput, buttonsOnly, noRepeatAbuse, noMacros
        /// An sTools hotkey takes a key Minecraft uses. A configuration conflict, not a speedrun rule.
        case hotkeyTakesGameKey

        public var rule: SpeedrunRule? {
            switch self {
            case .duplicateRebind, .shadowedRule, .chainedRebind, .hotkeyTakesGameKey: nil
            case .oneKeyOneInput: .oneKeyOneInput
            case .buttonsOnly: .buttonsOnly
            case .noRepeatAbuse: .noRepeatAbuse
            case .noMacros: .noMacros
            }
        }

        public var title: String {
            switch self {
            case .duplicateRebind: "Duplicate rebind"
            case .shadowedRule: "Shadowed rule"
            case .chainedRebind: "Chained rebind"
            case .hotkeyTakesGameKey: "Hotkey takes a game key"
            default: rule.map { "\($0.number) \u{2014} \($0.title.lowercased())" } ?? ""
            }
        }
    }

    public let kind: Kind
    /// The physical keys to mark on the diagram.
    public let keys: [KarabinerEvent]
    /// One sentence saying what is wrong, in the user's terms.
    public let message: String

    public var id: String { "\(kind.rawValue):\(message)" }

    public init(kind: Kind, keys: [KarabinerEvent], message: String) {
        self.kind = kind
        self.keys = keys
        self.message = message
    }
}
