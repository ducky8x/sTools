import AppKit
import Foundation
@testable import STPlatform
import Testing
@testable import sTools

// QA matrix (spec 9.2), global hotkeys: a bare key, ⇧-only and ⌥-only, holding a hotkey, a hotkey while Shift or
// Control are held, fn+F-key, sTools in front (fires) and behind, and paused while recording a key or typing. The
// hotkey center's own tests cover each rule; these run the shapes of a combination through the app model, with a
// registrar that matches modifiers exactly, as Carbon's `RegisterEventHotKey` does, so no real hotkey is registered.

/// A registrar that behaves the way macOS hands out hotkeys: a key event fires a registration only when its key and its
/// four modifiers (⌃ ⌥ ⇧ ⌘) are exactly the registered ones, pressing and releasing are reported apart, and a key held
/// down may be reported again.
@MainActor
final class ExactMatchRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    var onRelease: (@MainActor (UUID) -> Void)?
    private(set) var registered: [UUID: HotkeyCombo] = [:]
    /// Every combination macOS has been asked for, in order.
    private(set) var asked: [HotkeyCombo] = []

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        registered[id] = combo
        asked.append(combo)
    }

    func unregister(id: UUID) { registered[id] = nil }

    /// A key going down with these modifiers held. Whether anything fires is macOS's exact match.
    /// - Returns: whether a hotkey took the key (otherwise it goes on to the app in front).
    @discardableResult
    func keyDown(_ keyCode: UInt16, modifiers: HotkeyCombo.Modifiers = []) -> Bool {
        let combo = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        guard let id = registered.first(where: { $0.value == combo })?.key else { return false }
        onPress?(id)
        return true
    }

    @discardableResult
    func keyUp(_ keyCode: UInt16, modifiers: HotkeyCombo.Modifiers = []) -> Bool {
        let combo = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        guard let id = registered.first(where: { $0.value == combo })?.key else { return false }
        onRelease?(id)
        return true
    }
}

/// One way a hotkey's combination can be shaped.
struct HotkeyShape: Sendable, CustomTestStringConvertible {
    let name: String
    let combo: HotkeyCombo

    var testDescription: String { name }

    private static let f5: UInt16 = 96
    private static let a: UInt16 = 0

    static let all: [HotkeyShape] = [
        HotkeyShape(name: "a bare function key", combo: HotkeyCombo(keyCode: f5, modifiers: [])),
        HotkeyShape(name: "a bare typing key", combo: HotkeyCombo(keyCode: a, modifiers: [])),
        HotkeyShape(name: "⇧ only", combo: HotkeyCombo(keyCode: f5, modifiers: .shift)),
        HotkeyShape(name: "⌥ only", combo: HotkeyCombo(keyCode: f5, modifiers: .option)),
        HotkeyShape(name: "⌃ only", combo: HotkeyCombo(keyCode: f5, modifiers: .control)),
        HotkeyShape(name: "⌘ only", combo: HotkeyCombo(keyCode: f5, modifiers: .command)),
        HotkeyShape(name: "⇧ on a typing key", combo: HotkeyCombo(keyCode: a, modifiers: .shift)),
        HotkeyShape(name: "⌥ on a typing key", combo: HotkeyCombo(keyCode: a, modifiers: .option)),
        HotkeyShape(name: "⌃⌥⇧⌘ together", combo: HotkeyCombo(keyCode: f5, modifiers: .all)),
    ]
}

@MainActor
@Suite("Hotkeys by shape through the app")
struct HotkeyMatrixTests {
    private func make(scope: HotkeyScope = .sToolsAndMinecraft) -> (harness: Harness, registrar: ExactMatchRegistrar) {
        let registrar = ExactMatchRegistrar()
        let harness = Harness(accessibility: .granted, hotkeyRegistrar: registrar)
        harness.model.hotkeys.scope = scope
        harness.model.hotkeys.isEnabled = true
        return (harness, registrar)
    }

    // MARK: Pressing

    /// Every shape is taken as the person set it (no extra modifiers asked of macOS), a press switches its tool, and the
    /// next press switches it off again, each confirmed over the game once.
    @Test(arguments: HotkeyShape.all)
    func eachShapeFiresItsTool(shape: HotkeyShape) {
        let (harness, registrar) = make()
        let id = harness.model.hotkeys.add(combo: shape.combo, actions: [.toggle(.crosshair)])
        #expect(registrar.registered == [id: shape.combo], "macOS is asked for exactly this combination")
        #expect(harness.model.hotkeys.status(of: id) == .registered)

        #expect(registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers))
        registrar.keyUp(shape.combo.keyCode, modifiers: shape.combo.modifiers)
        #expect(harness.model.isOn(.crosshair))
        #expect(registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers))
        registrar.keyUp(shape.combo.keyCode, modifiers: shape.combo.modifiers)
        #expect(!harness.model.isOn(.crosshair))
        #expect(harness.hotkeyHUD.lines == ["Crosshair on", "Crosshair off"])
    }

    /// A key held down is one press, however many times macOS reports it, and the next press after the release counts.
    @Test(arguments: HotkeyShape.all)
    func holdingAShapeFiresOnce(shape: HotkeyShape) {
        let (harness, registrar) = make()
        harness.model.hotkeys.add(combo: shape.combo, actions: [.toggle(.crosshair)])
        for _ in 0..<12 { registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers) }
        #expect(harness.model.isOn(.crosshair))
        #expect(harness.hotkeyHUD.lines == ["Crosshair on"], "twelve reports of one held key are one press")
        registrar.keyUp(shape.combo.keyCode, modifiers: shape.combo.modifiers)
        registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers)
        #expect(!harness.model.isOn(.crosshair))
    }

    /// A hotkey is the key with exactly the modifiers set: with another modifier held (Shift to sneak, Control to sprint)
    /// macOS doesn't match it, and the key goes to the game. Whether macOS really behaves so on this Mac is a hand check
    /// in the M8 plan; this pins what sTools asks for, so the answer there decides the follow-up in spec 6.1.
    @Test func aBareKeyIsRegisteredBareSoSneakingOrSprintingKeepsItFromFiring() {
        let (harness, registrar) = make()
        let f5 = HotkeyCombo(keyCode: 96, modifiers: [])
        harness.model.hotkeys.add(combo: f5, actions: [.toggle(.crosshair)])
        #expect(registrar.asked == [f5])
        #expect(!registrar.keyDown(96, modifiers: .shift), "Shift held: not this hotkey")
        #expect(!registrar.keyDown(96, modifiers: .control), "Control held: not this hotkey")
        #expect(!harness.model.isOn(.crosshair))
        #expect(registrar.keyDown(96, modifiers: []))
        #expect(harness.model.isOn(.crosshair))
    }

    // MARK: fn and the function keys

    /// fn+F5 reaches sTools' own window as F5 with the fn flag. Caps Lock, fn and the keypad flag are no modifiers of a
    /// hotkey, so a bare F5 hotkey fires from the window, and ⇧F5 still needs the Shift.
    @Test func fnPlusAFunctionKeyFiresABareFunctionKeyHotkeyFromTheWindow() {
        let (harness, registrar) = make()
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 96, modifiers: []), actions: [.toggle(.crosshair)])
        _ = registrar.registered[id]
        let withFn = HotkeyKeyWatcher.modifiers(of: [.function, .capsLock])
        #expect(withFn.isEmpty)
        #expect(harness.model.hotkeys.handleKeyDown(keyCode: 96, modifiers: withFn, isRepeat: false))
        #expect(harness.model.isOn(.crosshair))
        #expect(!harness.model.hotkeys.handleKeyDown(keyCode: 96, modifiers: HotkeyKeyWatcher.modifiers(of: [.function, .shift]), isRepeat: false))
    }

    /// The editors tell Mac keyboard owners that F1–F12 may need fn; no other key is told so.
    @Test func onlyF1ToF12AreToldTheyMayNeedFn() {
        let notes = HotkeyShape.all.map { ($0.combo, HotkeyWording.functionKeyNote(for: $0.combo)) }
        for (combo, note) in notes {
            #expect((note != nil) == (combo.keyCode == 96), "\(combo.displayString)")
        }
        #expect(HotkeyWording.functionKeyNote(for: HotkeyCombo(keyCode: 105, modifiers: [])) == nil, "F13 has no media key")
    }

    // MARK: In front and behind

    /// With sTools or Minecraft in front the hotkey is registered; in any other app it isn't, so that app gets its keys.
    @Test(arguments: HotkeyShape.all)
    func behindAnotherAppNothingIsRegistered(shape: HotkeyShape) {
        let (harness, registrar) = make()
        let id = harness.model.hotkeys.add(combo: shape.combo, actions: [.toggle(.crosshair)])
        let center = harness.model.hotkeys
        #expect(registrar.registered == [id: shape.combo], "sTools in front")

        center.setFrontApp(.other)
        #expect(registrar.registered.isEmpty, "another app in front")
        #expect(!registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers), "the key goes to that app")
        #expect(!harness.model.isOn(.crosshair))

        center.setFrontApp(.minecraft)
        #expect(registrar.registered == [id: shape.combo], "Minecraft in front")
        center.setFrontApp(.other)
        center.setFrontApp(.sTools)
        #expect(registrar.registered == [id: shape.combo], "back in sTools")
    }

    @Test(arguments: HotkeyShape.all)
    func everywhereWorksBehindAnyApp(shape: HotkeyShape) {
        let (harness, registrar) = make(scope: .everywhere)
        let id = harness.model.hotkeys.add(combo: shape.combo, actions: [.toggle(.crosshair)])
        harness.model.hotkeys.setFrontApp(.other)
        #expect(registrar.registered == [id: shape.combo])
        #expect(registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers))
        #expect(harness.model.isOn(.crosshair))
    }

    // MARK: Paused

    /// While someone types in sTools, only the hotkeys that would take a typed key step aside (a letter, with or without
    /// ⇧ or ⌥); F-keys and ⌘ or ⌃ combinations keep working next to a text field.
    @Test(arguments: HotkeyShape.all)
    func typingStepsAsideOnlyForKeysThatWouldBeTyped(shape: HotkeyShape) {
        let (harness, registrar) = make()
        let id = harness.model.hotkeys.add(combo: shape.combo, actions: [.toggle(.crosshair)])
        harness.model.hotkeys.setPaused(true, for: .typing)
        if shape.combo.interferesWithTyping {
            #expect(registrar.registered.isEmpty, "the key goes to the text field")
            #expect(!registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers))
            #expect(!harness.model.isOn(.crosshair))
        } else {
            #expect(registrar.registered == [id: shape.combo])
            #expect(registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers))
            #expect(harness.model.isOn(.crosshair))
        }
        harness.model.hotkeys.setPaused(false, for: .typing)
        #expect(registrar.registered == [id: shape.combo], "typing over: back")
    }

    /// While a field records a key, or the Key Rebinder listens, every hotkey steps aside, so the key can be recorded.
    @Test(arguments: HotkeyShape.all, [HotkeyPause.recordingKey, .keyRebinder])
    func recordingAKeyPausesEveryShape(shape: HotkeyShape, reason: HotkeyPause) {
        let (harness, registrar) = make()
        let id = harness.model.hotkeys.add(combo: shape.combo, actions: [.toggle(.crosshair)])
        harness.model.hotkeys.setPaused(true, for: reason)
        #expect(registrar.registered.isEmpty)
        #expect(!registrar.keyDown(shape.combo.keyCode, modifiers: shape.combo.modifiers))
        #expect(!harness.model.isOn(.crosshair))
        #expect(harness.model.hotkeys.status(of: id) == .registered, "a pause isn't a refusal")
        harness.model.hotkeys.setPaused(false, for: reason)
        #expect(registrar.registered == [id: shape.combo])
    }

    /// A pause that starts while the key is down ends its press, so the timer's hold gesture and the next press aren't
    /// left waiting for a release macOS can no longer send.
    @Test func aPauseWhileAKeyIsDownLetsTheNextPressCount() {
        let (harness, registrar) = make()
        let combo = HotkeyCombo(keyCode: 96, modifiers: [])
        harness.model.hotkeys.add(combo: combo, actions: [.toggle(.crosshair)])
        registrar.keyDown(96)
        #expect(harness.model.isOn(.crosshair))
        harness.model.hotkeys.setPaused(true, for: .recordingKey)
        harness.model.hotkeys.setPaused(false, for: .recordingKey)
        registrar.keyDown(96)
        #expect(!harness.model.isOn(.crosshair), "the key came up while the hotkeys were paused: this is a new press")
    }
}
