import STPlatform

extension GoCommand {
    /// The command's shortcut as a hotkey combination: ⌃⌘3, ⌃⌘H, ⌘,. Keys are named in uppercase ("H"), as the
    /// menu shows them.
    var shortcutCombo: HotkeyCombo? {
        HotkeyCombo(character: Character(String(shortcutKey).uppercased()),
                    modifiers: shortcutHoldsControl ? [.control, .command] : .command)
    }

    /// Every shortcut of the Go menu, which no hotkey takes as a variant (spec 6.1): hotkeys fire with Shift or Control
    /// held as well, and the menu uses ⌃⌘0–⌃⌘6 and ⌃⌘H, so a hotkey on ⌘1 doesn't also fire with Control held.
    static var menuShortcuts: Set<HotkeyCombo> { Set(menu.compactMap(\.shortcutCombo)) }
}
