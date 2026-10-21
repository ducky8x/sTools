import STDesign
import STPlatform
import Testing

/// STDesign can't import STPlatform, so the recorder (`STShortcutKeys`) and hotkeys (`HotkeyCombo`) each keep a
/// key table. Every key code must read the same in both, or Home would show one name while recording and another
/// in the list, and a key one table knows would be unusable through the other.
@Suite("Hotkey key names")
struct HotkeyKeyNamesTests {
    @Test func theRecorderAndHotkeysNameEveryKeyTheSame() {
        for code in UInt16(0)..<256 {
            #expect(STShortcut(keyCode: code, modifiers: []).display == HotkeyCombo(keyCode: code, modifiers: []).displayString,
                    "key code \(code)")
            #expect(STShortcut(keyCode: code, modifiers: [.control, .option]).display
                    == HotkeyCombo(keyCode: code, modifiers: [.control, .option]).displayString,
                    "key code \(code)")
        }
    }

    @Test func modifiersCarryOverUnchanged() {
        let shortcut = STShortcut(keyCode: 83, modifiers: .all)
        #expect(HotkeyCombo(keyCode: shortcut.keyCode, modifierRawValue: shortcut.modifiers.rawValue) == HotkeyCombo(keyCode: 83, modifiers: .all))
    }
}
