@testable import STPlatform

extension SettingsStore {
    /// Turns Also fire while holding Shift or Control off in this store, for a test about the hotkeys themselves: with
    /// it on (its default) a center also registers each hotkey's variants, so what the fake registrar holds is more than
    /// the list. `HotkeyHeldModifierTests` covers the variants.
    func registerHotkeysExactly() {
        save(HotkeyHeldModifierSettings(alsoFiresWithShiftOrControl: false))
    }
}
