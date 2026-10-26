import Foundation

extension HotkeyWording {
    /// What Home ▸ Hotkeys has set for every hotkey, in one line for the other places that edit one (a tool page's
    /// Hotkey row, the Key Rebinder's key panel): "Hotkeys work in sTools and Minecraft · Key set: ⌘1–⌘5", "Hotkeys
    /// work in every app · Key set: Custom". Recognizing Minecraft needs Accessibility
    /// (`HotkeyFrontAppWatcher`), so without it In sTools and Minecraft means sTools alone, as Home says under Where
    /// hotkeys work: "Hotkeys work only in sTools until Accessibility is allowed · Key set: ⌘1–⌘5".
    public static func whereAndKeySet(scope: HotkeyScope, keySet: HotkeyKeySet?, accessibilityGranted: Bool) -> String {
        let place = switch scope {
        case .sToolsAndMinecraft:
            accessibilityGranted ? "in sTools and Minecraft" : "only in sTools until Accessibility is allowed"
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
            return "While hotkeys are on, Minecraft never gets \(combo.displayString), even in chat or the seed field."
        }
    }
}
