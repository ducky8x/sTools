import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import KeyRebinder

@Suite struct KeyboardLayoutTests {
    static let all: [KeyboardLayout] = KeyboardShape.allCases.flatMap { shape in
        KeyboardFormFactor.allCases.map { KeyboardLayout(shape: shape, formFactor: $0) }
    }

    @Test(arguments: all)
    func everyKeyIsDrawnOnce(_ layout: KeyboardLayout) {
        let events = layout.keys.map(\.event)
        #expect(Set(events).count == events.count, "\(layout.shape) \(layout.formFactor) repeats a key")
    }

    @Test(arguments: all)
    func noTwoKeysOverlap(_ layout: KeyboardLayout) {
        let parts = layout.keys.flatMap { key in key.frames.map { (key.event, $0) } }
        for (index, part) in parts.enumerated() {
            for other in parts[(index + 1)...] {
                let overlap = part.1.intersection(other.1)
                #expect(overlap.isNull || overlap.width < 0.001 || overlap.height < 0.001,
                        "\(part.0) overlaps \(other.0) on \(layout.shape) \(layout.formFactor)")
            }
        }
    }

    @Test(arguments: all)
    func everyKeyFitsInsideTheLayout(_ layout: KeyboardLayout) {
        let box = CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.001, dy: -0.001)
        for key in layout.keys {
            #expect(box.contains(key.bounds), "\(key.event) sticks out of \(layout.shape) \(layout.formFactor)")
        }
    }

    @Test(arguments: all)
    func everyKeyIsOneKarabinerKnows(_ layout: KeyboardLayout) {
        for key in layout.keys {
            #expect(KeyTable.shared.entry(for: key.event) != nil, "\(key.event) is not in Karabiner's key list")
            #expect(KeyTable.shared.virtualKeyCode(for: key.event) != nil, "\(key.event) has no Mac key code")
        }
    }

    @Test(arguments: all)
    func mainRowsAreFlushOnBothSides(_ layout: KeyboardLayout) {
        // The five main rows each run from 0 to 14.5 key units, like a real Mac keyboard.
        for row in 0..<5 {
            let top = 1.25 + CGFloat(row)
            let parts = layout.keys.flatMap(\.frames).filter { abs($0.minY - top) < 0.001 && $0.maxX <= 14.5 + 0.001 }
            #expect(abs((parts.map(\.minX).min() ?? -1)) < 0.001, "row \(row) of \(layout.shape) \(layout.formFactor) starts late")
            #expect(abs((parts.map(\.maxX).max() ?? -1) - 14.5) < 0.001, "row \(row) of \(layout.shape) \(layout.formFactor) ends short")
            let covered = parts.reduce(CGFloat(0)) { $0 + $1.width }
            #expect(abs(covered - 14.5) < 0.001, "row \(row) of \(layout.shape) \(layout.formFactor) has a gap")
        }
    }

    @Test func isoAndJISHaveATallReturnAndTheirOwnKeys() {
        let iso = KeyboardLayout(shape: .iso, formFactor: .laptop)
        #expect(iso.key(for: .key("return_or_enter"))?.frames.count == 2)
        #expect(iso.key(for: .key("non_us_backslash"))?.legend == "§")
        #expect(iso.key(for: .key("grave_accent_and_tilde")) != nil)

        let jis = KeyboardLayout(shape: .jis, formFactor: .laptop)
        #expect(jis.key(for: .key("return_or_enter"))?.frames.count == 2)
        #expect(jis.key(for: .key("japanese_eisuu")) != nil)
        #expect(jis.key(for: .key("international3"))?.legend == "¥")
        #expect(jis.key(for: .key("grave_accent_and_tilde")) == nil)

        let ansi = KeyboardLayout(shape: .ansi, formFactor: .laptop)
        #expect(ansi.key(for: .key("return_or_enter"))?.frames.count == 1)
        #expect(ansi.key(for: .key("non_us_backslash")) == nil)
    }

    @Test func fullSizeAddsKeypadNavigationAndHighFunctionKeys() {
        let full = KeyboardLayout(shape: .ansi, formFactor: .fullSize)
        let laptop = KeyboardLayout(shape: .ansi, formFactor: .laptop)
        for code in ["keypad_5", "keypad_enter", "home", "page_down", "f19", "right_control"] {
            #expect(full.key(for: .key(code)) != nil, "\(code) missing on full-size")
            #expect(laptop.key(for: .key(code)) == nil, "\(code) should not be on a laptop")
        }
        #expect(full.size.width > laptop.size.width)
    }

    @Test func mouseDrawsButtonsOneToEight() {
        #expect(MouseLayout.buttons.map(\.event).compactMap(MouseLayout.buttonNumber).sorted() == Array(1...8))
        #expect(MouseLayout.buttonNumber(of: .pointing("button12")) == 12)
        #expect(MouseLayout.buttonNumber(of: .key("a")) == nil)
    }

    @Test func aliasesFindTheOtherNamesOfAKey() {
        #expect(KeyTable.shared.aliases(of: .key("left_option")) == [.key("left_option"), .key("left_alt")])
        #expect(KeyTable.shared.aliases(of: .key("japanese_eisuu")) == [.key("japanese_eisuu"), .key("lang2")])
        #expect(KeyTable.shared.aliases(of: .key("a")) == [.key("a")])
        #expect(KeyTable.shared.aliases(of: .pointing("button1")) == [.pointing("button1")])
    }

    @Test func layoutTypesMapToShapes() {
        #expect(KeyboardLayoutDetector.shape(forLayoutType: UInt32(kKeyboardANSI)) == .ansi)
        #expect(KeyboardLayoutDetector.shape(forLayoutType: UInt32(kKeyboardISO)) == .iso)
        #expect(KeyboardLayoutDetector.shape(forLayoutType: UInt32(kKeyboardJIS)) == .jis)
        #expect(KeyboardLayoutDetector.shape(forLayoutType: UInt32(kKeyboardUnknown)) == .ansi)
    }
}

extension KeyboardLayout: CustomTestStringConvertible {
    public var testDescription: String { "\(shape.title) \(formFactor.title)" }
}
