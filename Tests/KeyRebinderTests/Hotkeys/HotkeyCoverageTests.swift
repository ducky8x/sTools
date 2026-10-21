import Testing
@testable import KeyRebinder
import STPlatform

/// STPlatform's hotkey key list and the Key Rebinder's key table are written separately; these keep them in step.
@Suite struct HotkeyCoverageTests {
    static let layouts: [KeyboardLayout] = KeyboardShape.allCases.flatMap { shape in
        KeyboardFormFactor.allCases.map { KeyboardLayout(shape: shape, formFactor: $0) }
    }

    /// Modifier keys (54–63) and Dashboard, Launchpad and Mission Control.
    static let systemKeys: Set<Int> = Set(54...63).union([130, 131, 160])

    @Test(arguments: layouts)
    func everyDrawnKeyButTheModifiersCanCarryAHotkey(_ layout: KeyboardLayout) {
        for key in layout.keys.map(\.event) where !KeyTable.shared.isModifier(key) {
            guard case .key(_, let keyCode) = HotkeyTarget.of(key, bindings: [:]) else {
                Issue.record("\(key) on \(layout.shape) \(layout.formFactor) can't carry a hotkey")
                continue
            }
            #expect(HotkeyCombo.isSupported(keyCode: keyCode), "\(key)")
        }
        for button in MouseLayout.buttons.map(\.event) {
            #expect(HotkeyTarget.of(button, bindings: [:]) == .mouseButton(sends: button))
        }
    }

    @Test func everyKarabinerVirtualKeyButModifiersAndSystemKeysCanBeAHotkey() {
        var seen = 0
        for virtualKey in 0..<256 where !KeyTable.shared.keyCodes(forVirtualKeyCode: virtualKey).isEmpty {
            seen += 1
            let supported = HotkeyCombo.isSupported(keyCode: UInt16(virtualKey))
            #expect(supported == !Self.systemKeys.contains(virtualKey), "virtual key \(virtualKey)")
        }
        for virtualKey in Self.systemKeys {
            #expect(!KeyTable.shared.keyCodes(forVirtualKeyCode: virtualKey).isEmpty, "virtual key \(virtualKey)")
        }
        #expect(seen - Self.systemKeys.count == HotkeyCombo.supportedKeyCodes.count)
    }

    @Test func everyHotkeyKeyIsAKarabinerVirtualKey() {
        for keyCode in HotkeyCombo.supportedKeyCodes {
            #expect(!KeyTable.shared.keyCodes(forVirtualKeyCode: Int(keyCode)).isEmpty, "virtual key \(keyCode)")
        }
    }
}
