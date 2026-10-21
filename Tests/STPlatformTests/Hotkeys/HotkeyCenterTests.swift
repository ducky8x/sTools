import Foundation
import Observation
import Synchronization
import Testing
@testable import STPlatform

/// Records what the center asks for, and reports presses and releases like the Carbon registrar. Never touches the
/// system.
@MainActor
private final class FakeRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    var onRelease: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]
    private(set) var log: [String] = []
    var refused: Set<HotkeyCombo> = []

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        if refused.contains(combo) {
            log.append("refused \(combo.displayString)")
            throw HotkeyRegistrationError(status: -9878)
        }
        active[id] = combo
        log.append("register \(combo.displayString)")
    }

    func unregister(id: UUID) {
        guard let combo = active.removeValue(forKey: id) else { return }
        log.append("unregister \(combo.displayString)")
    }

    /// The key goes down.
    func press(_ id: UUID) { onPress?(id) }
    /// The key comes back up.
    func release(_ id: UUID) { onRelease?(id) }
    /// A press and its release.
    func tap(_ id: UUID) {
        press(id)
        release(id)
    }
}

/// A registrar that doesn't report releases, like the fakes in the app's and the Key Rebinder's tests: it keeps the
/// protocol's default `onRelease`.
@MainActor
private final class PressOnlyRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]

    func register(_ combo: HotkeyCombo, id: UUID) throws { active[id] = combo }
    func unregister(id: UUID) { active[id] = nil }
}

@MainActor
private final class Harness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hotkey-center-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store: SettingsStore
    let registrar = FakeRegistrar()
    var tools: [HotkeyTool: Bool] = [:]
    var events: [HotkeyEvent] = []
    /// Each handler call, so tests can check a press arrives as one call.
    var presses: [[HotkeyEvent]] = []
    var center: HotkeyCenter!

    init(preload: HotkeySettings? = nil) async {
        store = SettingsStore(directory: directory, debounce: .milliseconds(1))
        if let preload {
            store.save(preload)
            await store.flush()
        }
        makeCenter()
    }

    func makeCenter() {
        center = HotkeyCenter(store: store, registrar: registrar,
                              toolStates: { [unowned self] in tools },
                              handler: { [unowned self] in
                                  events.append(contentsOf: $0)
                                  presses.append($0)
                              })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Advice from a stand-in for the Key Rebinder.
@MainActor
private final class FakeAdvisor: HotkeyAdvising {
    var advice: [HotkeyNote] = []

    func notes(for combo: HotkeyCombo) -> [HotkeyNote] { advice }
    func placement(of combo: HotkeyCombo) -> HotkeyPlacement? { nil }
    func selectKey(for combo: HotkeyCombo) -> Bool { false }
    func prepareAdvice() async {}
}

/// Counts observation change callbacks, which arrive on a `@Sendable` closure.
private final class ChangeCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])
private let ctrlOptV = HotkeyCombo(keyCode: 9, modifiers: [.control, .option])
private let pad1 = HotkeyCombo(keyCode: 83, modifiers: [])
private let bareC = HotkeyCombo(keyCode: 8, modifiers: [])
private let f5 = HotkeyCombo(keyCode: 96, modifiers: [])
private let f13 = HotkeyCombo(keyCode: 105, modifiers: [])

@Suite("HotkeyCenter")
@MainActor
struct HotkeyCenterTests {
    @Test func startsDisabledWithNothingRegistered() async {
        let h = await Harness()
        #expect(h.center.isEnabled == false)
        #expect(h.center.bindings.isEmpty)
        #expect(h.registrar.active.isEmpty)
    }

    @Test func masterSwitchOffRegistersNothingEvenWithBindings() async {
        let h = await Harness()
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        #expect(h.registrar.active.isEmpty)
        #expect(h.center.status(of: id) == .inactive)
    }

    @Test func turningTheMasterSwitchOnRegistersAndOffUnregisters() async {
        let h = await Harness()
        let a = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        let b = h.center.add(combo: ctrlOptV, actions: [.toggle(.nbbOverlay)])

        h.center.isEnabled = true
        #expect(h.registrar.active == [a: ctrlOptC, b: ctrlOptV])
        #expect(h.center.status(of: a) == .registered)

        h.center.isEnabled = false
        #expect(h.registrar.active.isEmpty)
        #expect(h.center.status(of: a) == .inactive)
    }

    @Test func addingWhileEnabledRegistersImmediately() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        #expect(h.registrar.active == [id: ctrlOptC])
        #expect(h.center.status(of: id) == .registered)
    }

    @Test func removingUnregisters() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.center.remove(id)
        #expect(h.registrar.active.isEmpty)
        #expect(h.center.bindings.isEmpty)
        #expect(h.center.status(of: id) == nil)
    }

    @Test func editingTheComboMovesTheRegistration() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.center.update(id, combo: ctrlOptV)
        #expect(h.registrar.active == [id: ctrlOptV])
        #expect(h.registrar.log == ["register ⌃⌥C", "unregister ⌃⌥C", "register ⌃⌥V"])
    }

    @Test func editingOnlyTheActionsLeavesTheRegistrationAlone() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.center.update(id, actions: [.toggle(.crosshair), .startStopRecording])
        #expect(h.registrar.log == ["register ⌃⌥C"])
        #expect(h.center.bindings.first?.actions == [.toggle(.crosshair), .startStopRecording])
    }

    @Test func updatingAnUnknownIdChangesNothing() async {
        let h = await Harness()
        h.center.update(UUID(), combo: ctrlOptC)
        #expect(h.center.bindings.isEmpty)
    }

    // MARK: Conflicts

    @Test func duplicateComboIsFlaggedAndNotRegistered() async {
        let h = await Harness()
        h.center.isEnabled = true
        let first = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        let second = h.center.add(combo: ctrlOptC, actions: [.toggle(.nbbOverlay)])
        #expect(h.center.status(of: first) == .registered)
        #expect(h.center.status(of: second) == .conflict(.alreadyUsedByYou(first)))
        #expect(h.registrar.active == [first: ctrlOptC])
    }

    @Test func duplicateIsFlaggedEvenWhileTheMasterSwitchIsOff() async {
        let h = await Harness()
        let first = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        let second = h.center.add(combo: ctrlOptC, actions: [.toggle(.nbbOverlay)])
        #expect(h.center.status(of: first) == .inactive)
        #expect(h.center.status(of: second) == .conflict(.alreadyUsedByYou(first)))
    }

    @Test func removingTheOwnerLetsTheDuplicateRegister() async {
        let h = await Harness()
        h.center.isEnabled = true
        let first = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        let second = h.center.add(combo: ctrlOptC, actions: [.toggle(.nbbOverlay)])
        h.center.remove(first)
        #expect(h.center.status(of: second) == .registered)
        #expect(h.registrar.active == [second: ctrlOptC])
    }

    @Test func editingADuplicateToAFreeComboRegistersIt() async {
        let h = await Harness()
        h.center.isEnabled = true
        _ = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        let second = h.center.add(combo: ctrlOptC, actions: [.toggle(.nbbOverlay)])
        h.center.update(second, combo: ctrlOptV)
        #expect(h.center.status(of: second) == .registered)
        #expect(h.registrar.active[second] == ctrlOptV)
    }

    @Test func systemRefusalIsFlagged() async {
        let h = await Harness()
        h.registrar.refused = [ctrlOptC]
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        #expect(h.center.status(of: id) == .conflict(.systemRefused))
        #expect(h.registrar.active.isEmpty)
    }

    @Test func refusedBindingIsRetriedOnTheNextChange() async {
        let h = await Harness()
        h.registrar.refused = [ctrlOptC]
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.registrar.refused = []
        h.center.update(id, actions: [.toggle(.crosshair), .toggle(.nbbOverlay)])
        #expect(h.center.status(of: id) == .registered)
    }

    @Test func invalidComboIsFlaggedAndNeverRegistered() async {
        let h = await Harness()
        h.center.isEnabled = true
        let reserved = h.center.add(combo: HotkeyCombo(keyCode: 12, modifiers: .command), actions: [.toggle(.crosshair)])
        let shiftKey = h.center.add(combo: HotkeyCombo(keyCode: 56, modifiers: .command), actions: [.toggle(.crosshair)])
        #expect(h.center.status(of: reserved) == .conflict(.invalidCombo(.reserved("Quit"))))
        #expect(h.center.status(of: shiftKey) == .conflict(.invalidCombo(.unsupportedKey)))
        #expect(h.registrar.active.isEmpty)
    }

    @Test func bindingWithoutActionsIsFlaggedAndNeverRegistered() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [])
        #expect(h.center.status(of: id) == .conflict(.noActions))
        #expect(h.registrar.active.isEmpty)
        h.center.update(id, actions: [.toggle(.crosshair)])
        #expect(h.center.status(of: id) == .registered)
    }

    @Test func conflictPreviewForTheEntryField() async {
        let h = await Harness()
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        #expect(h.center.conflict(for: ctrlOptC) == .alreadyUsedByYou(id))
        #expect(h.center.conflict(for: ctrlOptC, excluding: id) == nil)
        #expect(h.center.conflict(for: ctrlOptV) == nil)
        #expect(h.center.conflict(for: HotkeyCombo(keyCode: 12, modifiers: .command)) == .invalidCombo(.reserved("Quit")))
    }

    // MARK: Dispatch

    @Test func pressTogglesToolsPerTheRule() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair), .toggle(.nbbOverlay)])

        h.registrar.tap(id)
        #expect(h.events == [.setTool(.crosshair, isOn: true), .setTool(.nbbOverlay, isOn: true)])

        h.events.removeAll()
        h.tools = [.crosshair: true, .nbbOverlay: true]
        h.registrar.tap(id)
        #expect(h.events == [.setTool(.crosshair, isOn: false), .setTool(.nbbOverlay, isOn: false)])
    }

    @Test func pressReadsToolStatesFreshEachTime() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.tools = [.crosshair: true]
        h.registrar.tap(id)
        h.tools = [.crosshair: false]
        h.registrar.tap(id)
        #expect(h.events == [.setTool(.crosshair, isOn: false), .setTool(.crosshair, isOn: true)])
    }

    @Test func recordingActionSendsToggleRecordingAfterTools() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.startStopRecording, .toggle(.screenRecording)])
        h.registrar.press(id)
        #expect(h.events == [.setTool(.screenRecording, isOn: true), .toggleRecording])
    }

    @Test func aPressArrivesAsOneHandlerCall() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair), .toggle(.nbbOverlay), .startStopRecording])
        h.registrar.press(id)
        #expect(h.presses == [[.setTool(.crosshair, isOn: true), .setTool(.nbbOverlay, isOn: true), .toggleRecording]])
    }

    @Test func startTimerComesLastInItsPress() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer, .startStopRecording, .toggle(.crosshair)])
        h.registrar.press(id)
        #expect(h.presses == [[.setTool(.crosshair, isOn: true), .toggleRecording, .startTimer]])
    }

    /// Timer Overlay has no toggle, so the tools' states don't change what Start timer sends.
    @Test func startTimerAloneSendsOnlyStartTimer() async {
        let h = await Harness()
        h.center.isEnabled = true
        h.tools = [.crosshair: true, .nbbOverlay: false]
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.press(id)
        #expect(h.presses == [[.startTimer]])
    }

    @Test func pressWhileDisabledDoesNothing() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.center.isEnabled = false
        h.registrar.press(id)
        #expect(h.events.isEmpty)
    }

    @Test func pressOfARemovedBindingDoesNothing() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.center.remove(id)
        h.registrar.press(id)
        #expect(h.events.isEmpty)
    }

    /// A press counts only for a hotkey registered right now. One macOS delivered just before its hotkey was
    /// unregistered (a duplicate, a refusal, an edit) is stale: it isn't acted on, and its release isn't awaited.
    @Test func aPressForAHotkeyThatIsNotRegisteredIsIgnored() async {
        let h = await Harness()
        h.registrar.refused = [ctrlOptV]
        h.center.isEnabled = true
        let owner = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        let duplicate = h.center.add(combo: pad1, actions: [.startTimer])
        let refused = h.center.add(combo: ctrlOptV, actions: [.startTimer])
        h.registrar.tap(duplicate)
        h.registrar.tap(refused)
        #expect(h.presses.isEmpty)

        // Once the duplicate owns Pad 1, its presses count.
        h.center.remove(owner)
        h.registrar.tap(duplicate)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
    }

    // MARK: Releases

    /// The timer's hold-to-cancel needs the release (spec 5.6.7). It arrives as its own handler call.
    @Test func releasingAStartTimerKeySendsStartTimerReleased() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.toggle(.crosshair), .startTimer])
        h.registrar.press(id)
        h.registrar.release(id)
        #expect(h.presses == [[.setTool(.crosshair, isOn: true), .startTimer], [.startTimerReleased]])
    }

    @Test func onlyAStartTimerPressGetsAReleaseEvent() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair), .startStopRecording])
        h.registrar.tap(id)
        #expect(h.presses == [[.setTool(.crosshair, isOn: true), .toggleRecording]])
    }

    /// A release without its press (never pressed, released already, an unknown id) sends nothing.
    @Test func aReleaseCountsOnlyAfterItsPress() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.release(id)
        h.registrar.release(UUID())
        #expect(h.presses.isEmpty)

        h.registrar.press(id)
        h.registrar.release(id)
        h.registrar.release(id)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
    }

    /// Editing only the actions leaves the registration alone (with the pause off, that can happen while the key is
    /// down), and the release goes with what its press sent.
    @Test func aReleaseFollowsWhatItsPressSent() async {
        let h = await Harness()
        h.center.isEnabled = true
        let timer = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.press(timer)
        h.center.update(timer, actions: [.toggle(.crosshair)])
        h.registrar.release(timer)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])

        let other = h.center.add(combo: pad1, actions: [.toggle(.nbbOverlay)])
        h.registrar.press(other)
        h.center.update(other, actions: [.toggle(.nbbOverlay), .startTimer])
        h.registrar.release(other)
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.setTool(.nbbOverlay, isOn: true)]])
    }

    /// Releases are ignored while hotkeys pause, as presses are. A press macOS delivered just before the pause never
    /// counted, so its release doesn't either, even once the pause is over.
    @Test func aReleaseWhilePausedDoesNothing() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.center.appIsActive = true
        h.registrar.press(id)
        h.registrar.release(id)
        h.registrar.press(id)
        h.center.appIsActive = false
        h.registrar.release(id)
        #expect(h.presses.isEmpty)
    }

    /// Once its hotkey is unregistered, macOS can't report a key's release, so the center sends it itself: the timer
    /// never waits for a release that can't come. A late release from macOS changes nothing.
    @Test func pausingWhileAKeyIsDownSendsItsRelease() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.press(id)
        h.center.appIsActive = true
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
        #expect(h.registrar.active.isEmpty)

        h.registrar.release(id)
        h.center.appIsActive = false
        h.registrar.release(id)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
    }

    @Test func turningHotkeysOffWhileAKeyIsDownSendsItsRelease() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.press(id)
        h.center.isEnabled = false
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])

        h.registrar.release(id)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
    }

    @Test func editingOrRemovingAHotkeyWhileItsKeyIsDownSendsItsRelease() async {
        let h = await Harness()
        h.center.isEnabled = true
        let edited = h.center.add(combo: f13, actions: [.startTimer])
        let emptied = h.center.add(combo: f5, actions: [.startTimer])
        let removed = h.center.add(combo: pad1, actions: [.startTimer])
        for id in [edited, emptied, removed] { h.registrar.press(id) }
        h.presses.removeAll()

        h.center.update(edited, combo: ctrlOptC)
        #expect(h.presses == [[.startTimerReleased]])
        h.center.update(emptied, actions: [])
        #expect(h.presses == [[.startTimerReleased], [.startTimerReleased]])
        h.center.remove(removed)
        #expect(h.presses == [[.startTimerReleased], [.startTimerReleased], [.startTimerReleased]])

        for id in [edited, emptied, removed] { h.registrar.release(id) }
        #expect(h.presses.count == 3)
    }

    @Test func unregisteringAKeyDownWithoutStartTimerSendsNothing() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.registrar.press(id)
        h.center.appIsActive = true
        h.center.isEnabled = false
        #expect(h.presses == [[.setTool(.crosshair, isOn: true)]])
    }

    /// A registrar that doesn't report releases keeps the protocol's default `onRelease`, which never calls back and
    /// reads nil. The center then marks no key down, so it never sends a release on the registrar's behalf.
    @Test func aRegistrarWithoutReleasesGetsNoReleaseSent() async {
        let h = await Harness()
        let registrar = PressOnlyRegistrar()
        let center = HotkeyCenter(store: h.store, registrar: registrar, toolStates: { [:] },
                                  handler: { [unowned h] in h.presses.append($0) })
        #expect(registrar.onRelease == nil)
        center.isEnabled = true
        let id = center.add(combo: f13, actions: [.startTimer])
        registrar.onPress?(id)
        center.appIsActive = true
        center.isEnabled = false
        #expect(h.presses == [[.startTimer]])
    }

    // MARK: Held keys

    /// Whether macOS repeats a held hotkey is still to be confirmed on hardware (spec 6.1). Either way, a press for a
    /// key that is still down is ignored until its release.
    @Test func aHeldKeysRepeatsAreIgnoredUntilItsRelease() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.registrar.press(id)
        h.tools = [.crosshair: true]
        h.registrar.press(id)
        h.registrar.press(id)
        #expect(h.presses == [[.setTool(.crosshair, isOn: true)]])

        h.registrar.release(id)
        h.registrar.press(id)
        #expect(h.presses == [[.setTool(.crosshair, isOn: true)], [.setTool(.crosshair, isOn: false)]])
    }

    /// A second press within 0.4 s cancels the timer (spec 5.6.2), so a held key's repeats must never reach it.
    @Test func aHeldTimerKeyNeverLooksLikeADoublePress() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.press(id)
        h.registrar.press(id)
        h.registrar.press(id)
        h.registrar.release(id)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
    }

    /// The timer's double press is two separate presses, each with its release.
    @Test func separatePressesStillCount() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.tap(id)
        h.registrar.tap(id)
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer], [.startTimerReleased]])
    }

    @Test func eachHotkeysKeyIsTrackedOnItsOwn() async {
        let h = await Harness()
        h.center.isEnabled = true
        let timer = h.center.add(combo: f13, actions: [.startTimer])
        let crosshair = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.registrar.press(timer)
        h.registrar.press(crosshair)
        h.registrar.press(timer)
        h.registrar.release(crosshair)
        h.registrar.press(crosshair)
        #expect(h.presses == [[.startTimer], [.setTool(.crosshair, isOn: true)], [.setTool(.crosshair, isOn: true)]])
    }

    /// An unregistration forgets the key, so once hotkeys are live again its next press counts, although macOS never
    /// reported the release.
    @Test func aPauseForgetsTheKeysThatWereDown() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.press(id)
        h.center.appIsActive = true
        h.center.appIsActive = false
        h.registrar.press(id)
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer]])
    }

    /// A registrar that doesn't report releases can't tell a held key from a new press, so every press counts.
    @Test func aRegistrarWithoutReleasesCountsEveryPress() async {
        let h = await Harness()
        let registrar = PressOnlyRegistrar()
        let center = HotkeyCenter(store: h.store, registrar: registrar, toolStates: { [:] },
                                  handler: { [unowned h] in h.presses.append($0) })
        center.isEnabled = true
        let id = center.add(combo: f13, actions: [.startTimer])
        registrar.onPress?(id)
        registrar.onPress?(id)
        #expect(h.presses == [[.startTimer], [.startTimer]])
    }

    // MARK: Persistence

    @Test func settingsPersistAndRegisterOnNextLaunch() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair), .startStopRecording])
        await h.store.flush()

        let relaunched = FakeRegistrar()
        let center = HotkeyCenter(store: SettingsStore(directory: h.directory), registrar: relaunched,
                                  toolStates: { [:] }, handler: { _ in })
        #expect(center.isEnabled)
        #expect(center.bindings.map(\.id) == [id])
        #expect(relaunched.active == [id: ctrlOptC])
    }

    @Test func preloadedDisabledSettingsRegisterNothing() async {
        let binding = HotkeyBinding(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        let h = await Harness(preload: HotkeySettings(isEnabled: false, bindings: [binding]))
        #expect(h.center.bindings == [binding])
        #expect(h.registrar.active.isEmpty)
    }

    @Test func showsConfirmationDefaultsOnAndPersistsWithoutTouchingRegistrations() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        let logBefore = h.registrar.log
        #expect(h.center.showsConfirmation)

        h.center.showsConfirmation = false
        await h.store.flush()
        #expect(h.registrar.log == logBefore)
        #expect(h.center.status(of: id) == .registered)

        let relaunched = HotkeyCenter(store: SettingsStore(directory: h.directory), registrar: FakeRegistrar(),
                                      toolStates: { [:] }, handler: { _ in })
        #expect(!relaunched.showsConfirmation)
    }

    @Test func settingTheSwitchToItsCurrentValueDoesNothing() async {
        let h = await Harness()
        h.center.isEnabled = false
        #expect(h.registrar.log.isEmpty)
        #expect(h.store.writeCount == 0)
    }

    // MARK: Any key

    @Test func aBareComboRegisters() async {
        let h = await Harness()
        h.center.isEnabled = true
        let pad = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        let c = h.center.add(combo: bareC, actions: [.toggle(.nbbOverlay)])
        #expect(h.center.status(of: pad) == .registered)
        #expect(h.center.status(of: c) == .registered)
        #expect(h.registrar.active == [pad: pad1, c: bareC])
        #expect(h.center.conflict(for: HotkeyCombo(keyCode: 49, modifiers: [])) == nil) // Space alone
    }

    // MARK: Pause while sTools is in front

    @Test func aNewCenterIsNotInFront() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        #expect(!h.center.appIsActive)
        #expect(!h.center.isPaused)
        #expect(h.center.pausesWhileSToolsIsActive)
        #expect(h.registrar.active == [id: pad1])
    }

    @Test func hotkeysPauseWhileSToolsIsInFront() async {
        let h = await Harness()
        h.center.isEnabled = true
        let a = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        let b = h.center.add(combo: ctrlOptV, actions: [.toggle(.nbbOverlay)])

        h.center.appIsActive = true
        #expect(h.center.isPaused)
        #expect(h.registrar.active.isEmpty)
        #expect(h.center.status(of: a) == .registered)
        #expect(h.center.status(of: b) == .registered)

        h.center.appIsActive = false
        #expect(!h.center.isPaused)
        #expect(h.registrar.active == [a: pad1, b: ctrlOptV])
        #expect(h.center.status(of: a) == .registered)
        #expect(h.center.status(of: b) == .registered)
    }

    @Test func theSettingKeepsHotkeysLiveInFront() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.center.appIsActive = true
        #expect(h.registrar.active.isEmpty)

        h.center.pausesWhileSToolsIsActive = false
        #expect(!h.center.isPaused)
        #expect(h.registrar.active == [id: pad1])
        h.registrar.press(id)
        #expect(h.events == [.setTool(.crosshair, isOn: true)])

        h.center.pausesWhileSToolsIsActive = true
        #expect(h.center.isPaused)
        #expect(h.registrar.active.isEmpty)
    }

    @Test func thePauseSettingPersists() async {
        let h = await Harness()
        h.center.pausesWhileSToolsIsActive = false
        await h.store.flush()
        let relaunched = HotkeyCenter(store: SettingsStore(directory: h.directory), registrar: FakeRegistrar(),
                                      toolStates: { [:] }, handler: { _ in })
        #expect(!relaunched.pausesWhileSToolsIsActive)
    }

    @Test func aPressWhilePausedDoesNothing() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.center.appIsActive = true
        // A press macOS delivered just before the pause began.
        h.registrar.press(id)
        #expect(h.events.isEmpty)

        h.center.appIsActive = false
        h.registrar.press(id)
        #expect(h.events == [.setTool(.crosshair, isOn: true)])
    }

    @Test func pausingWhileOffChangesNothing() async {
        let h = await Harness()
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.center.appIsActive = true
        #expect(!h.center.isPaused)
        #expect(h.registrar.log.isEmpty)
        #expect(h.center.status(of: id) == .inactive)
        h.center.appIsActive = false
        #expect(h.registrar.log.isEmpty)
        #expect(h.center.status(of: id) == .inactive)
    }

    @Test func aComboAddedWhilePausedIsTriedOnce() async {
        let h = await Harness()
        h.center.isEnabled = true
        h.center.appIsActive = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        #expect(h.registrar.log == ["register Pad 1", "unregister Pad 1"])
        #expect(h.center.status(of: id) == .registered)
        #expect(h.registrar.active.isEmpty)

        h.center.update(id, actions: [.toggle(.crosshair), .toggle(.nbbOverlay)])
        #expect(h.registrar.log == ["register Pad 1", "unregister Pad 1"])

        h.center.appIsActive = false
        #expect(h.registrar.log == ["register Pad 1", "unregister Pad 1", "register Pad 1"])
        #expect(h.registrar.active == [id: pad1])
    }

    @Test func aComboRegisteredBeforeThePauseIsNotTriedAgain() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.center.appIsActive = true
        h.center.update(id, actions: [.toggle(.nbbOverlay)])
        #expect(h.registrar.log == ["register Pad 1", "unregister Pad 1"])
        #expect(h.center.status(of: id) == .registered)
    }

    @Test func aRefusalShowsWhilePausedAndIsRetriedOnResume() async {
        let h = await Harness()
        h.registrar.refused = [pad1]
        h.center.isEnabled = true
        h.center.appIsActive = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        #expect(h.center.status(of: id) == .conflict(.systemRefused))
        #expect(h.registrar.active.isEmpty)

        h.registrar.refused = []
        h.center.appIsActive = false
        #expect(h.center.status(of: id) == .registered)
        #expect(h.registrar.active == [id: pad1])
    }

    /// Another app can take a combination after the probe accepted it; the refusal on resume makes the next
    /// pause try it again.
    @Test func aRefusalOnResumeIsForgottenAndTriedAgainNextPause() async {
        let h = await Harness()
        h.center.isEnabled = true
        h.center.appIsActive = true
        let id = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.registrar.refused = [pad1]
        h.center.appIsActive = false
        #expect(h.center.status(of: id) == .conflict(.systemRefused))

        h.registrar.refused = []
        h.center.appIsActive = true
        #expect(h.center.status(of: id) == .registered)
        #expect(h.registrar.log.suffix(2) == ["register Pad 1", "unregister Pad 1"])
        #expect(h.registrar.active.isEmpty)
    }

    @Test func conflictsStillReportWhilePaused() async {
        let h = await Harness()
        h.center.isEnabled = true
        h.center.appIsActive = true
        let first = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        let duplicate = h.center.add(combo: pad1, actions: [.toggle(.nbbOverlay)])
        let reserved = h.center.add(combo: HotkeyCombo(keyCode: 12, modifiers: .command), actions: [.toggle(.crosshair)])
        let empty = h.center.add(combo: ctrlOptV, actions: [])
        #expect(h.center.status(of: first) == .registered)
        #expect(h.center.status(of: duplicate) == .conflict(.alreadyUsedByYou(first)))
        #expect(h.center.status(of: reserved) == .conflict(.invalidCombo(.reserved("Quit"))))
        #expect(h.center.status(of: empty) == .conflict(.noActions))
        #expect(h.center.conflict(for: pad1) == .alreadyUsedByYou(first))
        #expect(h.registrar.active.isEmpty)
    }

    @Test func activeBindingsAreAcceptedFirstOwnersOnlyWhileOn() async {
        let h = await Harness()
        h.registrar.refused = [ctrlOptV]
        let first = h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.center.add(combo: pad1, actions: [.toggle(.nbbOverlay)])                                // duplicate
        h.center.add(combo: HotkeyCombo(keyCode: 56, modifiers: []), actions: [.toggle(.crosshair)]) // Shift key
        h.center.add(combo: bareC, actions: [])                                                     // no actions
        h.center.add(combo: ctrlOptV, actions: [.toggle(.crosshair)])                              // refused
        let last = h.center.add(combo: f5, actions: [.startStopRecording])
        #expect(h.center.activeBindings.isEmpty)

        h.center.isEnabled = true
        #expect(h.center.activeBindings.map(\.id) == [first, last])

        h.center.appIsActive = true
        #expect(h.center.isPaused)
        #expect(h.center.activeBindings.map(\.id) == [first, last])

        h.center.isEnabled = false
        #expect(h.center.activeBindings.isEmpty)
    }

    @Test func statusesAreAssignedOnlyWhenTheyChange() async {
        let h = await Harness()
        h.center.isEnabled = true
        h.center.add(combo: pad1, actions: [.toggle(.crosshair)])
        h.center.add(combo: ctrlOptV, actions: [.toggle(.nbbOverlay)])

        let changes = ChangeCounter()
        withObservationTracking { _ = h.center.statuses } onChange: { changes.increment() }
        h.center.appIsActive = true
        h.center.appIsActive = false
        h.center.appIsActive = true
        h.center.showsConfirmation = false
        #expect(changes.value == 0)

        h.center.add(combo: f5, actions: [.toggle(.crosshair)])
        #expect(changes.value == 1)
    }

    // MARK: Notes

    @Test func notesComeInOrder() async throws {
        let h = await Harness()
        let advisor = FakeAdvisor()
        advisor.advice = [HotkeyNote(tone: .note, text: "Advisor note"), HotkeyNote(tone: .caution, text: "Advisor caution")]
        h.center.advisor = advisor
        let typing = try #require(HotkeyWording.typingNote(for: bareC))
        #expect(h.center.notes(for: bareC) == [HotkeyNote(tone: .caution, text: "Advisor caution"),
                                               HotkeyNote(tone: .note, text: typing),
                                               HotkeyNote(tone: .note, text: "Advisor note")])

        let fn = try #require(HotkeyWording.functionKeyNote(for: f5))
        #expect(h.center.notes(for: f5) == [HotkeyNote(tone: .caution, text: "Advisor caution"),
                                            HotkeyNote(tone: .note, text: "Advisor note"),
                                            HotkeyNote(tone: .note, text: fn)])

        h.center.advisor = nil
        #expect(h.center.notes(for: f5) == [HotkeyNote(tone: .note, text: fn)])
        #expect(h.center.notes(for: ctrlOptC).isEmpty)
    }

    @Test func theAdvisorIsHeldWeakly() async {
        let h = await Harness()
        do {
            let advisor = FakeAdvisor()
            h.center.advisor = advisor
            #expect(h.center.advisor === advisor)
        }
        #expect(h.center.advisor == nil)
    }
}
