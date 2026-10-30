import STPlatform

extension GoCommand {
    /// The command's shortcut as a hotkey combination: ⌃⌘3, ⌘,.
    var shortcutCombo: HotkeyCombo? {
        HotkeyCombo(character: shortcutKey, modifiers: shortcutHoldsControl ? [.control, .command] : .command)
    }

    /// Every shortcut of the Go menu, which no hotkey takes as a variant (spec 6.1): hotkeys fire with Shift or Control
    /// held as well, and the menu uses ⌃⌘0–⌃⌘6, so a hotkey on ⌘1 doesn't also fire with Control held.
    static var menuShortcuts: Set<HotkeyCombo> { Set(menu.compactMap(\.shortcutCombo)) }
}
