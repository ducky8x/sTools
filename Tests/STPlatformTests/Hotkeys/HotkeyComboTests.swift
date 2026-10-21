import Foundation
import Testing
@testable import STPlatform

@Suite("HotkeyCombo")
struct HotkeyComboTests {
    private let c: UInt16 = 8
    private let f5: UInt16 = 96
    private let space: UInt16 = 49

    @Test func displayUsesMacOrderControlOptionShiftCommand() {
        #expect(HotkeyCombo(keyCode: c, modifiers: [.control, .option]).displayString == "⌃⌥C")
        #expect(HotkeyCombo(keyCode: c, modifiers: [.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘C")
        #expect(HotkeyCombo(keyCode: f5, modifiers: .shift).displayString == "⇧F5")
        #expect(HotkeyCombo(keyCode: space, modifiers: [.command, .shift]).displayString == "⇧⌘Space")
    }

    @Test func displayCoversEveryFunctionKey() {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        let names = codes.map { HotkeyCombo(keyCode: $0, modifiers: []).displayString }
        #expect(names == (1...20).map { "F\($0)" })
    }

    @Test func unknownKeyCodeShowsItsNumber() {
        #expect(HotkeyCombo(keyCode: 999, modifiers: .command).displayString == "⌘Key 999")
    }

    @Test func modifierBitsOutsideTheFourAreDropped() {
        let combo = HotkeyCombo(keyCode: c, modifierRawValue: 0xFFFF_FFFF)
        #expect(combo.modifiers == .all)
    }

    @Test func modifiersUseCarbonValues() {
        #expect(HotkeyCombo.Modifiers.command.rawValue == 256)
        #expect(HotkeyCombo.Modifiers.shift.rawValue == 512)
        #expect(HotkeyCombo.Modifiers.option.rawValue == 2048)
        #expect(HotkeyCombo.Modifiers.control.rawValue == 4096)
    }

    // MARK: Validation

    @Test func commonCombosAreValid() {
        #expect(HotkeyCombo(keyCode: c, modifiers: [.control, .option]).isValid)
        #expect(HotkeyCombo(keyCode: c, modifiers: .command).isValid)
        #expect(HotkeyCombo(keyCode: c, modifiers: [.control, .shift]).isValid)
        #expect(HotkeyCombo(keyCode: 126, modifiers: [.control, .option]).isValid)
    }

    /// C, 1, Space, Return, Esc, Delete, ←, -, Pad 1 and Pad Clear: any known key works alone.
    @Test func unmodifiedKeysAreValid() {
        for code: UInt16 in [c, 18, 49, 36, 53, 51, 123, 27, 83, 71] {
            #expect(HotkeyCombo(keyCode: code, modifiers: []).issue == nil, "key code \(code)")
        }
    }

    @Test func functionKeysNeedNoModifier() {
        #expect(HotkeyCombo(keyCode: f5, modifiers: []).isValid)
        #expect(HotkeyCombo(keyCode: 90, modifiers: []).isValid)
        #expect(HotkeyCombo(keyCode: f5, modifiers: .shift).isValid)
    }

    @Test func shiftOrOptionAloneIsValid() {
        #expect(HotkeyCombo(keyCode: c, modifiers: .shift).issue == nil)
        #expect(HotkeyCombo(keyCode: c, modifiers: .option).issue == nil)
        #expect(HotkeyCombo(keyCode: c, modifiers: [.shift, .option]).issue == nil)
        #expect(HotkeyCombo(keyCode: 123, modifiers: .shift).issue == nil)
    }

    @Test func unsupportedKeyCodesAreRejected() {
        #expect(HotkeyCombo(keyCode: 56, modifiers: .command).issue == .unsupportedKey) // Shift key itself
        #expect(HotkeyCombo(keyCode: 999, modifiers: .command).issue == .unsupportedKey)
        #expect(HotkeyCombo(keyCode: 999, modifiers: []).issue == .unsupportedKey)
    }

    @Test func newKeysAreSupportedAndNamed() {
        let named: [(UInt16, String)] = [
            (10, "§"), (71, "Pad Clear"), (93, "¥"), (94, "_"), (95, "Pad ,"), (102, "英数"), (104, "かな"), (110, "Menu"),
        ]
        for (code, name) in named {
            #expect(HotkeyCombo(keyCode: code, modifiers: []).displayString == name)
            #expect(HotkeyCombo(keyCode: code, modifiers: [.control, .option]).displayString == "⌃⌥" + name)
            #expect(HotkeyCombo(keyCode: code, modifiers: []).isValid, "key code \(code)")
        }
    }

    /// Modifier keys, Caps Lock and fn (54–63), Dashboard, Launchpad and Mission Control: macOS can't take them.
    @Test func modifierAndSystemKeysStayUnsupported() {
        for code: UInt16 in Array(54...63) + [130, 131, 160] {
            #expect(!HotkeyCombo.isSupported(keyCode: code), "key code \(code)")
            #expect(HotkeyCombo(keyCode: code, modifiers: []).issue == .unsupportedKey, "key code \(code)")
            #expect(HotkeyCombo(keyCode: code, modifiers: [.command, .control]).issue == .unsupportedKey, "key code \(code)")
        }
    }

    /// Every virtual key in Karabiner-Elements' table except the 13 above.
    @Test func supportedKeyCodesListExactlyTheSupportedKeys() {
        let codes = HotkeyCombo.supportedKeyCodes
        #expect(codes.count == 107)
        #expect(Set(codes).count == codes.count)
        for code in UInt16(0)..<256 {
            #expect(HotkeyCombo.isSupported(keyCode: code) == codes.contains(code), "key code \(code)")
        }
        for code: UInt16 in [10, 71, 93, 94, 95, 102, 104, 110, 8, 83, 90, 114] {
            #expect(HotkeyCombo.isSupported(keyCode: code), "key code \(code)")
        }
    }

    // MARK: Key facts

    @Test func keyNameLeavesTheModifiersOut() {
        #expect(HotkeyCombo(keyCode: c, modifiers: [.control, .option]).keyName == "C")
        #expect(HotkeyCombo(keyCode: f5, modifiers: .shift).keyName == "F5")
        #expect(HotkeyCombo(keyCode: 83, modifiers: []).keyName == "Pad 1")
        #expect(HotkeyCombo(keyCode: 999, modifiers: .command).keyName == "Key 999")
    }

    @Test func spokenKeyNamesSpellSymbolsOut() {
        let spoken: [(UInt16, String)] = [
            (c, "C"), (83, "Keypad 1"), (51, "Delete"), (117, "Forward Delete"), (53, "Escape"), (36, "Return"),
            (48, "Tab"), (123, "Left Arrow"), (116, "Page Up"), (71, "Keypad Clear"), (10, "Section"), (79, "F18"),
            (999, "Key 999"),
        ]
        for (code, name) in spoken {
            #expect(HotkeyCombo(keyCode: code, modifiers: .command).spokenKeyName == name)
        }
    }

    @Test func functionKeyNumberIsOneToTwenty() {
        #expect(HotkeyCombo(keyCode: f5, modifiers: []).functionKeyNumber == 5)
        #expect(HotkeyCombo(keyCode: 79, modifiers: .shift).functionKeyNumber == 18)
        #expect(HotkeyCombo(keyCode: 122, modifiers: []).functionKeyNumber == 1)
        #expect(HotkeyCombo(keyCode: 90, modifiers: []).functionKeyNumber == 20)
        #expect(HotkeyCombo(keyCode: c, modifiers: []).functionKeyNumber == nil)
        #expect(HotkeyCombo(keyCode: 999, modifiers: []).functionKeyNumber == nil)
    }

    @Test func keyKinds() {
        #expect(HotkeyCombo(keyCode: c, modifiers: []).keyKind == .typing)
        #expect(HotkeyCombo(keyCode: 83, modifiers: []).keyKind == .typing)
        #expect(HotkeyCombo(keyCode: 104, modifiers: []).keyKind == .typing)
        #expect(HotkeyCombo(keyCode: 116, modifiers: []).keyKind == .typing)
        #expect(HotkeyCombo(keyCode: f5, modifiers: []).keyKind == .function)
        #expect(HotkeyCombo(keyCode: 114, modifiers: []).keyKind == .other)
        #expect(HotkeyCombo(keyCode: 110, modifiers: []).keyKind == .other)
        #expect(HotkeyCombo(keyCode: 999, modifiers: []).keyKind == nil)
    }

    @Test(arguments: [
        // Typing and editing keys without ⌘ or ⌃ take that key from every other app.
        (HotkeyCombo(keyCode: 8, modifiers: []), true),
        (HotkeyCombo(keyCode: 8, modifiers: .shift), true),
        (HotkeyCombo(keyCode: 8, modifiers: .option), true),
        (HotkeyCombo(keyCode: 8, modifiers: [.shift, .option]), true),
        (HotkeyCombo(keyCode: 49, modifiers: []), true),   // Space
        (HotkeyCombo(keyCode: 36, modifiers: []), true),   // Return
        (HotkeyCombo(keyCode: 53, modifiers: []), true),   // Esc
        (HotkeyCombo(keyCode: 123, modifiers: []), true),  // ←
        (HotkeyCombo(keyCode: 83, modifiers: []), true),   // Pad 1
        (HotkeyCombo(keyCode: 71, modifiers: []), true),   // Pad Clear
        (HotkeyCombo(keyCode: 10, modifiers: []), true),   // §
        // ⌘ or ⌃ makes it a shortcut, not typing; F-keys, Help and Menu never type.
        (HotkeyCombo(keyCode: 8, modifiers: .control), false),
        (HotkeyCombo(keyCode: 8, modifiers: .command), false),
        (HotkeyCombo(keyCode: 8, modifiers: [.control, .option]), false),
        (HotkeyCombo(keyCode: 96, modifiers: []), false),  // F5
        (HotkeyCombo(keyCode: 96, modifiers: .shift), false),
        (HotkeyCombo(keyCode: 79, modifiers: []), false),  // F18
        (HotkeyCombo(keyCode: 114, modifiers: []), false), // Help
        (HotkeyCombo(keyCode: 110, modifiers: []), false), // Menu
    ])
    func interferesWithTyping(combo: HotkeyCombo, expected: Bool) {
        #expect(combo.interferesWithTyping == expected, "\(combo.displayString)")
    }

    @Test func lacksCommandAndControl() {
        #expect(HotkeyCombo(keyCode: c, modifiers: []).lacksCommandAndControl)
        #expect(HotkeyCombo(keyCode: c, modifiers: [.shift, .option]).lacksCommandAndControl)
        #expect(HotkeyCombo(keyCode: f5, modifiers: .option).lacksCommandAndControl)
        #expect(!HotkeyCombo(keyCode: c, modifiers: .control).lacksCommandAndControl)
        #expect(!HotkeyCombo(keyCode: c, modifiers: [.command, .shift]).lacksCommandAndControl)
        #expect(!HotkeyCombo(keyCode: c, modifiers: [.control, .option]).lacksCommandAndControl)
    }

    @Test func systemReservedCombosAreRejected() {
        #expect(HotkeyCombo(keyCode: 12, modifiers: .command).issue == .reserved("Quit"))
        #expect(HotkeyCombo(keyCode: 48, modifiers: .command).issue == .reserved("App switcher"))
        #expect(HotkeyCombo(keyCode: 49, modifiers: .command).issue == .reserved("Spotlight"))
        #expect(HotkeyCombo(keyCode: 53, modifiers: [.command, .option]).issue == .reserved("Force quit"))
    }

    @Test func everyReservedEntryIsOtherwiseValidAndRejected() {
        for (combo, reason) in HotkeyCombo.reservedCombos {
            #expect(combo.issue == .reserved(reason), "\(combo.displayString)")
        }
    }

    @Test func reservedListHasNoDuplicates() {
        let combos = HotkeyCombo.reservedCombos.map(\.combo)
        #expect(Set(combos).count == combos.count)
    }

    @Test func similarButNotReservedCombosPass() {
        #expect(HotkeyCombo(keyCode: 12, modifiers: [.command, .option]).isValid)
        #expect(HotkeyCombo(keyCode: 48, modifiers: .control).isValid)
    }

    // MARK: Codable

    @Test func roundTripsAsKeyCodeAndRawModifiers() throws {
        let combo = HotkeyCombo(keyCode: c, modifiers: [.control, .option])
        let data = try JSONEncoder().encode(combo)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(json == ["keyCode": 8, "modifiers": 6144])
        #expect(try JSONDecoder().decode(HotkeyCombo.self, from: data) == combo)
    }

    @Test func decodingMasksUnknownModifierBits() throws {
        let data = Data(#"{"keyCode": 8, "modifiers": 16640}"#.utf8) // 16384 + 256
        #expect(try JSONDecoder().decode(HotkeyCombo.self, from: data).modifiers == .command)
    }
}
