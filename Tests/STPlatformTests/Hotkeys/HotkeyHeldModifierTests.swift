import Foundation
import Testing
@testable import STPlatform

// Home ▸ Hotkeys ▸ Advanced ▸ Also fire while holding Shift or Control (spec 6.1, revision 45). macOS matches a hotkey's
// modifiers exactly, so with the option on each hotkey also registers with Shift, Control and both added, and a press of
// any of them is the hotkey's own. Nothing here registers a real hotkey: the registrar is a fake that records what it is
// asked for.

/// Records what is registered, refuses what `refused` holds, and plays presses and releases back by combination.
@MainActor
private final class HeldRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    var onRelease: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]
    var refused: Set<HotkeyCombo> = []
    private(set) var refusals: [HotkeyCombo] = []

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        if refused.contains(combo) {
            refusals.append(combo)
            throw HotkeyRegistrationError(status: -9878)
        }
        active[id] = combo
    }

    func unregister(id: UUID) { active[id] = nil }

    /// Every combination registered now.
    var combos: Set<HotkeyCombo> { Set(active.values) }

    /// The registration made for `combo`.
    func id(of combo: HotkeyCombo) -> UUID? { active.first { $0.value == combo }?.key }

    func press(_ combo: HotkeyCombo) { if let id = id(of: combo) { onPress?(id) } }
    func release(_ combo: HotkeyCombo) { if let id = id(of: combo) { onRelease?(id) } }
}

@MainActor
private final class Harness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hotkey-held-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store: SettingsStore
    let registrar = HeldRegistrar()
    var events: [HotkeyEvent] = []
    var center: HotkeyCenter!

    /// - Parameters:
    ///   - hotkeys: the saved list, on, as a person set it.
    ///   - option: the saved option; nil leaves the file out, as before it was ever changed (on).
    init(_ hotkeys: [(HotkeyCombo, [HotkeyAction])] = [], option: Bool? = nil, menuShortcuts: Set<HotkeyCombo> = []) async {
        store = SettingsStore(directory: directory, debounce: .milliseconds(1))
        store.save(HotkeySettings(isEnabled: true, bindings: hotkeys.map { HotkeyBinding(combo: $0.0, actions: $0.1) }))
        if let option { store.save(HotkeyHeldModifierSettings(alsoFiresWithShiftOrControl: option)) }
        await store.flush()
        makeCenter(menuShortcuts: menuShortcuts)
    }

    func makeCenter(menuShortcuts: Set<HotkeyCombo> = []) {
        center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, menuShortcuts: menuShortcuts,
                              handler: { [unowned self] in events.append(contentsOf: $0) })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func combo(_ keyCode: UInt16, _ modifiers: HotkeyCombo.Modifiers = []) -> HotkeyCombo {
    HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
}

private let f6 = 97 as UInt16
private let letterC = 8 as UInt16
private let digit1 = 18 as UInt16
private let digit3 = 20 as UInt16
private let digit4 = 21 as UInt16
private let digit5 = 23 as UInt16

@Suite("Hotkeys also firing with Shift or Control")
@MainActor
struct HotkeyHeldModifierTests {
    // MARK: Which combinations

    @Test func aBareKeyGainsShiftControlAndBoth() {
        let variants = combo(f6).shiftAndControlVariants
        #expect(variants == [combo(f6, .shift), combo(f6, .control), combo(f6, [.shift, .control])])
    }

    @Test func aCombinationAlreadyHoldingOneGainsTheOther() {
        #expect(combo(f6, .shift).shiftAndControlVariants == [combo(f6, [.shift, .control])])
        #expect(combo(f6, .control).shiftAndControlVariants == [combo(f6, [.shift, .control])])
        #expect(combo(f6, [.shift, .control]).shiftAndControlVariants.isEmpty)
    }

    @Test func commandAndOptionStayOnEveryVariant() {
        let variants = combo(digit1, [.command, .option]).shiftAndControlVariants
        #expect(variants.map(\.modifiers) == [[.command, .option, .shift], [.command, .option, .control], .all])
        #expect(variants.allSatisfy { $0.keyCode == digit1 })
    }

    // MARK: Registering

    @Test func eachHotkeyAlsoRegistersWithShiftAndControlByDefault() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        #expect(h.center.alsoFiresWithShiftOrControl)
        #expect(h.registrar.combos == [combo(f6), combo(f6, .shift), combo(f6, .control), combo(f6, [.shift, .control])])
    }

    @Test func withTheOptionOffOnlyTheHotkeysThemselvesRegister() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])], option: false)
        #expect(!h.center.alsoFiresWithShiftOrControl)
        #expect(h.registrar.combos == [combo(f6)])
    }

    @Test func theOptionTakesEffectAtOnceBothWays() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        h.center.alsoFiresWithShiftOrControl = false
        #expect(h.registrar.combos == [combo(f6)])
        h.center.alsoFiresWithShiftOrControl = true
        #expect(h.registrar.combos.count == 4)
    }

    @Test func aVariantNeverTakesAnotherHotkeysCombination() async {
        // ⇧F6 is hotkey B's own, whichever of the two comes first: A's Shift variant is left out, B's key stays B's.
        for order in [[0, 1], [1, 0]] {
            let list: [(HotkeyCombo, [HotkeyAction])] = [(combo(f6), [.toggle(.crosshair)]), (combo(f6, .shift), [.toggle(.nbbOverlay)])]
            let h = await Harness(order.map { list[$0] })
            let b = h.center.bindings.first { $0.actions == [.toggle(.nbbOverlay)] }
            #expect(b.map { h.registrar.active[$0.id] } == combo(f6, .shift), "B keeps ⇧F6 itself")
            #expect(h.registrar.combos == [combo(f6), combo(f6, .shift), combo(f6, .control), combo(f6, [.shift, .control])])
        }
    }

    @Test func twoVariantsOfOneCombinationGoToTheFirstHotkey() async {
        let a = HotkeyBinding(combo: combo(f6, .control), actions: [.toggle(.crosshair)])
        let b = HotkeyBinding(combo: combo(f6, .shift), actions: [.toggle(.nbbOverlay)])
        let h = await Harness([(a.combo, a.actions), (b.combo, b.actions)])
        #expect(h.registrar.combos == [combo(f6, .control), combo(f6, .shift), combo(f6, [.shift, .control])])
        h.registrar.press(combo(f6, [.shift, .control]))
        #expect(h.events == [.setTool(.crosshair, isOn: true)], "the first one in the list owns the shared variant")
    }

    @Test func aVariantOfAnSToolsMenuShortcutIsLeftOut() async {
        let goToCrosshair = combo(digit1, [.control, .command])
        let h = await Harness([(combo(digit1, .command), [.toggle(.crosshair)])], menuShortcuts: [goToCrosshair])
        #expect(h.registrar.combos == [combo(digit1, .command), combo(digit1, [.shift, .command]), combo(digit1, [.shift, .control, .command])])
    }

    /// A menu shortcut only exists while sTools is the app in front, so only then does a variant on it collide: in the
    /// game ⌘1 also fires with Control held, and in sTools ⌃⌘1 stays the Go menu's.
    @Test func aMenuShortcutsVariantIsLeftOutOnlyWhileSToolsIsInFront() async {
        let goToCrosshair = combo(digit1, [.control, .command])
        let h = await Harness([(combo(digit1, .command), [.toggle(.crosshair)])], menuShortcuts: [goToCrosshair])
        #expect(h.center.frontApp == .sTools, "a center nobody tells acts as if sTools were in front")
        #expect(!h.registrar.combos.contains(goToCrosshair))

        h.center.setFrontApp(.minecraft)
        #expect(h.registrar.combos.contains(goToCrosshair))
        #expect(h.registrar.combos.count == 4)

        h.center.setFrontApp(.sTools)
        #expect(!h.registrar.combos.contains(goToCrosshair), "back in sTools the menu has it again")
        #expect(h.registrar.combos.count == 3)

        h.center.scope = .everywhere
        h.center.setFrontApp(.other)
        #expect(h.registrar.combos.contains(goToCrosshair), "another app has no sTools menu to collide with")
    }

    @Test func aVariantMacOSKeepsIsLeftOut() async {
        // ⇧⌘3 is the screenshot shortcut and ⌃⇧⌘3 the one to the clipboard.
        let h = await Harness([(combo(digit3, .command), [.toggle(.crosshair)])])
        #expect(h.registrar.combos == [combo(digit3, .command), combo(digit3, [.control, .command])])
        #expect(HotkeyCombo(keyCode: digit3, modifiers: [.shift, .command]).issue != nil)
    }

    @Test func theNewInstallsKeySetKeepsItsOwnKeysAndLeavesOutWhatCollides() async {
        let keys = [(combo(digit1, .command), HotkeyAction.toggle(.crosshair)), (combo(digit3, .command), .toggle(.nbbOverlay)),
                    (combo(digit4, .command), .startStopRecording), (combo(digit5, .command), .toggle(.windowBackdrop))]
        let go = Set([digit1, digit3, digit4, digit5].map { combo($0, [.control, .command]) })
        let h = await Harness(keys.map { ($0.0, [$0.1]) }, menuShortcuts: go)
        let live = h.registrar.combos
        for (key, _) in keys { #expect(live.contains(key), "\(key.displayString) stays registered") }
        #expect(!live.contains { $0.modifiers == [.control, .command] }, "no ⌃⌘ digit, the Go menu's")
        #expect(!live.contains(combo(digit3, [.shift, .command])) && !live.contains(combo(digit4, [.shift, .command])))
        #expect(!live.contains(combo(digit5, [.shift, .command])))
        #expect(!live.contains(combo(digit3, [.shift, .control, .command])) && !live.contains(combo(digit4, [.shift, .control, .command])),
                "⌃⇧⌘3 and ⌃⇧⌘4 are macOS's screenshots to the clipboard")
        #expect(live.contains(combo(digit1, [.shift, .command])) && live.contains(combo(digit5, [.shift, .control, .command])))
    }

    @Test func aRefusedVariantIsSkippedWithoutMarkingTheHotkey() async {
        let h = await Harness()
        h.registrar.refused = [combo(f6, .shift)]
        let id = h.center.add(combo: combo(f6), actions: [.toggle(.crosshair)])
        #expect(h.center.status(of: id) == .registered)
        #expect(h.registrar.combos == [combo(f6), combo(f6, .control), combo(f6, [.shift, .control])])
        #expect(h.registrar.refusals == [combo(f6, .shift)])
    }

    @Test func aHotkeyMacOSRefusedOrAlreadyUsedGetsNoVariants() async {
        let h = await Harness()
        h.registrar.refused = [combo(f6)]
        let refused = h.center.add(combo: combo(f6), actions: [.toggle(.crosshair)])
        #expect(h.center.status(of: refused) == .conflict(.systemRefused))
        #expect(h.registrar.combos.isEmpty)

        let first = h.center.add(combo: combo(letterC, .command), actions: [.toggle(.nbbOverlay)])
        let again = h.center.add(combo: combo(letterC, .command), actions: [.toggle(.windowBackdrop)])
        #expect(h.center.status(of: first) == .registered)
        #expect(h.center.status(of: again) == .conflict(.alreadyUsedByYou(first)))
        #expect(h.registrar.combos.count == 4, "the first one's, no more for the duplicate")
    }

    @Test func variantsComeAndGoWithTheirHotkey() async {
        let h = await Harness()
        let id = h.center.add(combo: combo(f6), actions: [.toggle(.crosshair)])
        #expect(h.registrar.combos.count == 4)
        h.center.update(id, combo: combo(letterC, .command))
        #expect(h.registrar.combos == [combo(letterC, .command), combo(letterC, [.shift, .command]),
                                       combo(letterC, [.control, .command]), combo(letterC, [.shift, .control, .command])])
        h.center.remove(id)
        #expect(h.registrar.combos.isEmpty)
    }

    @Test func variantsFollowTheMasterSwitch() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        h.center.isEnabled = false
        #expect(h.registrar.combos.isEmpty)
        h.center.isEnabled = true
        #expect(h.registrar.combos.count == 4)
    }

    @Test func variantsStepAsideWithTheirHotkeyAndTypingOnlyPausesTheOnesThatTakeATypedKey() async {
        let h = await Harness([(combo(letterC), [.toggle(.crosshair)])])
        #expect(h.registrar.combos.count == 4)
        h.center.setPaused(true, for: .typing)
        // Bare C and ⇧C would type a letter; anything with ⌃ doesn't.
        #expect(h.registrar.combos == [combo(letterC, .control), combo(letterC, [.shift, .control])])
        h.center.setPaused(false, for: .typing)
        #expect(h.registrar.combos.count == 4)
        h.center.setPaused(true, for: .recordingKey)
        #expect(h.registrar.combos.isEmpty)
        h.center.setPaused(false, for: .recordingKey)
        #expect(h.registrar.combos.count == 4)
    }

    @Test func variantsWorkWhereTheirHotkeyDoes() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        h.center.setFrontApp(.other)
        #expect(h.registrar.combos.isEmpty)
        h.center.setFrontApp(.minecraft)
        #expect(h.registrar.combos.count == 4)
    }

    // MARK: Pressing

    @Test(arguments: [HotkeyCombo.Modifiers.shift, .control, [.shift, .control]])
    func aPressOfAVariantIsThatHotkeysOwn(extra: HotkeyCombo.Modifiers) async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        h.registrar.press(combo(f6, extra))
        h.registrar.release(combo(f6, extra))
        #expect(h.events == [.setTool(.crosshair, isOn: true)])
    }

    /// The variants and the hotkey are one key: while one is held, a press through another is a repeat, not a second press.
    @Test func aHotkeyAndItsVariantsShareOnePress() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        h.registrar.press(combo(f6, .shift))
        h.registrar.press(combo(f6))
        #expect(h.events.count == 1, "the second is a repeat of the held key")
        h.registrar.release(combo(f6, .shift))
        h.registrar.press(combo(f6))
        #expect(h.events.count == 2, "after the release it is a new press")
    }

    @Test func startTimerHeldThroughAVariantGetsItsRelease() async {
        let h = await Harness([(combo(f6), [.startTimer])])
        h.registrar.press(combo(f6, .control))
        h.registrar.release(combo(f6, .control))
        #expect(h.events == [.startTimer, .startTimerReleased])
    }

    @Test func aVariantRemovedWhileItsKeyIsDownReleasesStartTimer() async {
        let h = await Harness([(combo(f6), [.startTimer])])
        h.registrar.press(combo(f6, .shift))
        h.center.alsoFiresWithShiftOrControl = false
        #expect(h.events == [.startTimer, .startTimerReleased], "macOS can't report that release any more")
        h.registrar.press(combo(f6))
        #expect(h.events == [.startTimer, .startTimerReleased, .startTimer], "and the key is free again")
    }

    @Test func aKeyReachingTheWindowWithShiftHeldFiresTheHotkey() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        #expect(h.center.handleKeyDown(keyCode: f6, modifiers: .shift, isRepeat: false))
        #expect(h.events == [.setTool(.crosshair, isOn: true)])
        #expect(h.center.handleKeyUp(keyCode: f6))

        h.center.alsoFiresWithShiftOrControl = false
        #expect(!h.center.handleKeyDown(keyCode: f6, modifiers: .shift, isRepeat: false), "with the option off it's an ordinary key")
        #expect(h.events.count == 1)
    }

    // MARK: Stored on its own

    @Test func theOptionIsOnUntilSomeoneTurnsItOffAndNothingIsWrittenBeforeThen() async {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)])])
        await h.store.flush()
        let file = h.directory.appending(path: "\(HotkeyHeldModifierSettings.name).json")
        #expect(h.center.alsoFiresWithShiftOrControl)
        #expect(!FileManager.default.fileExists(atPath: file.path), "starting up writes nothing")

        h.center.alsoFiresWithShiftOrControl = false
        await h.store.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
        let relaunched = HotkeyCenter(store: SettingsStore(directory: h.directory), registrar: HeldRegistrar(), toolStates: { [:] }, handler: { _ in })
        #expect(!relaunched.alsoFiresWithShiftOrControl, "the choice is kept")
    }

    /// A variant never changes the saved hotkey list: `hotkeys.json` is byte for byte what it was, however the option
    /// is set and whatever the variants do.
    @Test func hotkeysJSONIsNeverTouched() async throws {
        let h = await Harness([(combo(f6), [.toggle(.crosshair)]), (combo(digit1, .command), [.startTimer])])
        let file = h.directory.appending(path: "\(HotkeySettings.name).json")
        let before = try Data(contentsOf: file)
        h.center.alsoFiresWithShiftOrControl = false
        h.center.alsoFiresWithShiftOrControl = true
        h.registrar.tap(combo(f6, .shift))
        await h.store.flush()
        #expect(try Data(contentsOf: file) == before)
        #expect(h.center.bindings.map(\.combo) == [combo(f6), combo(digit1, .command)])
    }

    @Test func aMissingOrWrongOptionIsOn() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(HotkeyHeldModifierSettings.self, from: Data("{}".utf8)).alsoFiresWithShiftOrControl)
        #expect(try decoder.decode(HotkeyHeldModifierSettings.self, from: Data(#"{"alsoFiresWithShiftOrControl":"no"}"#.utf8))
            .alsoFiresWithShiftOrControl)
        #expect(!(try decoder.decode(HotkeyHeldModifierSettings.self, from: Data(#"{"alsoFiresWithShiftOrControl":false}"#.utf8))
            .alsoFiresWithShiftOrControl))
        #expect(HotkeyHeldModifierSettings.defaultValue.alsoFiresWithShiftOrControl)
        #expect(HotkeyHeldModifierSettings.name == "hotkeyHeldModifiers" && HotkeyHeldModifierSettings.version == 1)
    }
}

extension HeldRegistrar {
    /// A press and its release.
    fileprivate func tap(_ combo: HotkeyCombo) {
        press(combo)
        release(combo)
    }
}
