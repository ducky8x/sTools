import Foundation

/// Advice about a hotkey from a module STPlatform can't see: the Key Rebinder knows the keyboard, Karabiner's
/// rebinds and Minecraft's keybinds. `HotkeyCenter.advisor` holds it, so Home shows the Key Rebinder's advice
/// without importing its types, and both hotkey editors get the same words from `HotkeyCenter.notes(for:)`.
@MainActor
public protocol HotkeyAdvising: AnyObject {
    /// What to know about `combo` beyond what STPlatform says itself: a caution when Minecraft uses its key, and
    /// notes such as the modifiers that keep it from firing. Any order; `HotkeyCenter.notes(for:)` sorts them.
    func notes(for combo: HotkeyCombo) -> [HotkeyNote]

    /// Where `combo`'s key comes from on the chosen keyboard, for the caption under a Home row. Nil when there is
    /// nothing to place it on (no keyboard chosen yet).
    func placement(of combo: HotkeyCombo) -> HotkeyPlacement?

    /// Selects the first drawn key that sends `combo`'s key, ready for the Key Rebinder page to show it.
    /// False when no drawn key sends it.
    func selectKey(for combo: HotkeyCombo) -> Bool

    /// Loads what the advice reads (karabiner.json, Minecraft's keybinds). Never runs `karabiner_cli`.
    func prepareAdvice() async
}

/// One line of advice about a hotkey. Notes never block saving.
public struct HotkeyNote: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        /// Something to know: the key stops typing elsewhere, it may need fn.
        case note
        /// Something it takes away: Minecraft uses the key.
        case caution
    }

    public let tone: Tone
    public let text: String

    public init(tone: Tone, text: String) {
        self.tone = tone
        self.text = text
    }
}

/// Where a hotkey's key comes from on the chosen keyboard.
public struct HotkeyPlacement: Hashable, Sendable {
    /// "On Caps Lock", "On Caps Lock and Mouse Button 4", "No key on your keyboard sends F20". Nil when the key
    /// simply sends itself, which needs no caption.
    public let text: String?
    /// Whether a drawn key sends it, so "Show on Keyboard" has a key to select.
    public let canShow: Bool

    public init(text: String?, canShow: Bool) {
        self.text = text
        self.canShow = canShow
    }
}
