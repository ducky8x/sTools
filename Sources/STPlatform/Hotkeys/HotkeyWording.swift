import Foundation

extension HotkeyAction {
    /// The action's name on chips, in summaries and in what VoiceOver says. One exhaustive switch, so a new action
    /// can't ship without a name.
    public var title: String {
        switch self {
        case .toggle(.nbbOverlay): "NBB Overlay"
        case .toggle(.windowBackdrop): "Window Backdrop"
        case .toggle(.crosshair): "Crosshair"
        case .startStopRecording: "Screen Recording"
        case .startTimer: "Start timer"
        }
    }

    /// The tool the action belongs to, by name, for what's said about the tool's own key: Start timer is Timer
    /// Overlay's. The same names as the sidebar's.
    public var toolTitle: String {
        self == .startTimer ? "Timer Overlay" : title
    }
}

/// The words both hotkey editors use (Home ▸ Hotkeys and the Key Rebinder's key panel), so they always match.
/// Plain placeholder wording until M9.
public enum HotkeyWording {
    /// The actions in order, joined with " + ": "Crosshair + NBB Overlay".
    public static func summary(_ actions: [HotkeyAction]) -> String {
        actions.map(\.title).joined(separator: " + ")
    }

    /// The actions as VoiceOver says them: "Crosshair", "Crosshair and NBB Overlay",
    /// "Crosshair, NBB Overlay and Screen Recording".
    public static func spokenSummary(_ actions: [HotkeyAction]) -> String {
        let titles = actions.map(\.title)
        guard let last = titles.last else { return "" }
        guard titles.count > 1 else { return last }
        return titles.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The question before `combo` replaces a tool's own key instead of becoming a second one
    /// (`HotkeyCenter.ownHotkeyReplaced(bySaving:editing:)`): "Use F6 for Crosshair?".
    public static func replaceOwnKeyQuestion(_ own: HotkeyBinding, with combo: HotkeyCombo) -> String {
        "Use \(combo.displayString) for \(own.actions.first?.toolTitle ?? "")?"
    }

    /// What Replace does, under the question: "Crosshair has one key of its own, ⌘1. This replaces it with F6. Your
    /// other hotkeys stay as they are."
    public static func replaceOwnKeyWarning(_ own: HotkeyBinding, with combo: HotkeyCombo) -> String {
        let tool = own.actions.first?.toolTitle ?? ""
        return "\(tool) has one key of its own, \(own.combo.displayString). This replaces it with \(combo.displayString). "
            + "Your other hotkeys stay as they are."
    }

    /// Why a combination can't be a hotkey: "Unsupported key", "Reserved: Spotlight".
    public static func issueText(_ issue: HotkeyComboIssue) -> String {
        switch issue {
        case .unsupportedKey: "Unsupported key"
        case .reserved(let name): "Reserved: \(name)"
        }
    }

    /// Why a hotkey can't work. A duplicate reads "Already used above" in Home's list (`inList`), where the hotkey
    /// that owns the combination is a row above, and "Already used by another hotkey" anywhere else. A refusal of
    /// a combination without ⌘ or ⌃ adds that some macOS versions need one (15.0 and 15.1 reportedly refused
    /// ⌥-only hotkeys).
    public static func conflictText(_ conflict: HotkeyConflict, combo: HotkeyCombo, inList: Bool) -> String {
        switch conflict {
        case .alreadyUsedByYou: inList ? "Already used above" : "Already used by another hotkey"
        case .systemRefused: combo.lacksCommandAndControl ? "Refused by macOS. Some versions need ⌘ or ⌃." : "Refused by macOS"
        case .invalidCombo(let issue): issueText(issue)
        case .noActions: "No actions"
        }
    }

    /// The problem to show beside a hotkey, or nil when there is none: it is registered, off with the master
    /// switch, or unknown.
    public static func statusNote(_ status: HotkeyStatus?, combo: HotkeyCombo, inList: Bool = true) -> String? {
        guard case .conflict(let conflict) = status else { return nil }
        return conflictText(conflict, combo: combo, inList: inList)
    }

    /// For a typing or editing key without ⌘ or ⌃ (`HotkeyCombo.interferesWithTyping`): while hotkeys are on,
    /// the hotkey takes that key from every other app. Nil for every other combination.
    public static func typingNote(for combo: HotkeyCombo) -> String? {
        guard combo.interferesWithTyping else { return nil }
        return "While hotkeys are on, other apps never get \(combo.displayString), not even Minecraft's chat or seed field."
    }

    /// For F1 to F12, with any modifiers: a Mac keyboard sends its media keys there unless fn is held (or
    /// standard function keys are turned on), so the hotkey may need fn. Nil for every other key.
    public static func functionKeyNote(for combo: HotkeyCombo) -> String? {
        guard let number = combo.functionKeyNumber, number <= 12 else { return nil }
        return "On a Mac keyboard you may need to hold fn with \(combo.keyName)."
    }

    /// The combination as VoiceOver says it, modifiers in the order ⌃⌥⇧⌘: "Option F18", "Keypad 1",
    /// "Control Shift Delete".
    public static func spokenName(for combo: HotkeyCombo) -> String {
        var words: [String] = []
        if combo.modifiers.contains(.control) { words.append("Control") }
        if combo.modifiers.contains(.option) { words.append("Option") }
        if combo.modifiers.contains(.shift) { words.append("Shift") }
        if combo.modifiers.contains(.command) { words.append("Command") }
        words.append(combo.spokenKeyName)
        return words.joined(separator: " ")
    }
}
