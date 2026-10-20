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

    @Test func unmodifiedNonFunctionKeysAreRejected() {
        for code: UInt16 in [c, 18, 49, 36, 53, 51, 123, 27] {
            #expect(HotkeyCombo(keyCode: code, modifiers: []).issue == .needsModifier)
        }
    }

    @Test func functionKeysNeedNoModifier() {
        #expect(HotkeyCombo(keyCode: f5, modifiers: []).isValid)
        #expect(HotkeyCombo(keyCode: 90, modifiers: []).isValid)
        #expect(HotkeyCombo(keyCode: f5, modifiers: .shift).isValid)
    }

    @Test func shiftOrOptionAloneIsRejectedOnOrdinaryKeys() {
        #expect(HotkeyCombo(keyCode: c, modifiers: .shift).issue == .needsCommandOrControl)
        #expect(HotkeyCombo(keyCode: c, modifiers: .option).issue == .needsCommandOrControl)
        #expect(HotkeyCombo(keyCode: c, modifiers: [.shift, .option]).issue == .needsCommandOrControl)
        #expect(HotkeyCombo(keyCode: 123, modifiers: .shift).issue == .needsCommandOrControl)
    }

    @Test func unsupportedKeyCodesAreRejected() {
        #expect(HotkeyCombo(keyCode: 56, modifiers: .command).issue == .unsupportedKey) // Shift key itself
        #expect(HotkeyCombo(keyCode: 999, modifiers: .command).issue == .unsupportedKey)
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
