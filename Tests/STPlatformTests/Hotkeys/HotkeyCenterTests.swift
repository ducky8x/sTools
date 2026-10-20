import Foundation
import Testing
@testable import STPlatform

/// Records what the center asks for. Never touches the system.
@MainActor
private final class FakeRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
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

    func press(_ id: UUID) { onPress?(id) }
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

private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])
private let ctrlOptV = HotkeyCombo(keyCode: 9, modifiers: [.control, .option])

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
        let bare = h.center.add(combo: HotkeyCombo(keyCode: 8, modifiers: []), actions: [.toggle(.crosshair)])
        #expect(h.center.status(of: reserved) == .conflict(.invalidCombo(.reserved("Quit"))))
        #expect(h.center.status(of: bare) == .conflict(.invalidCombo(.needsModifier)))
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

        h.registrar.press(id)
        #expect(h.events == [.setTool(.crosshair, isOn: true), .setTool(.nbbOverlay, isOn: true)])

        h.events.removeAll()
        h.tools = [.crosshair: true, .nbbOverlay: true]
        h.registrar.press(id)
        #expect(h.events == [.setTool(.crosshair, isOn: false), .setTool(.nbbOverlay, isOn: false)])
    }

    @Test func pressReadsToolStatesFreshEachTime() async {
        let h = await Harness()
        h.center.isEnabled = true
        let id = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair)])
        h.tools = [.crosshair: true]
        h.registrar.press(id)
        h.tools = [.crosshair: false]
        h.registrar.press(id)
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
}
