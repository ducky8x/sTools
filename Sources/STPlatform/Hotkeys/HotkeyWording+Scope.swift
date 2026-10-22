import Foundation

extension HotkeyWording {
    /// What Home ▸ Hotkeys has set for every hotkey, in one line for the other places that edit one (a tool page's
    /// Hotkey row, Timer Overlay's Key row, the Key Rebinder's key panel): "Hotkeys work in sTools and Minecraft · Key
    /// set: ⌘1–⌘5", "Hotkeys work in every app · Key set: Custom".
    public static func whereAndKeySet(scope: HotkeyScope, keySet: HotkeyKeySet?) -> String {
        let place = switch scope {
        case .sToolsAndMinecraft: "in sTools and Minecraft"
        case .everywhere: "in every app"
        }
        return "Hotkeys work \(place) · Key set: \(HotkeyKeySet.name(of: keySet))"
    }

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
