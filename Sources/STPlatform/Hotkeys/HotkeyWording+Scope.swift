import Foundation

extension HotkeyWording {
    /// The typing note for where hotkeys work (`HotkeyCombo.interferesWithTyping`): with Everywhere no other app gets
    /// the key; with In sTools and Minecraft other apps do, and only Minecraft loses it. Nil for every other
    /// combination.
    public static func typingNote(for combo: HotkeyCombo, scope: HotkeyScope) -> String? {
        switch scope {
        case .everywhere:
            return typingNote(for: combo)
        case .sToolsAndMinecraft:
            guard combo.interferesWithTyping else { return nil }
            return "While hotkeys are on, Minecraft never gets \(combo.displayString), not even in its chat or seed field."
        }
    }
}
