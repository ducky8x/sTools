import Foundation
import Testing
@testable import STPlatform

/// Records what the center registers and lets a test press a hotkey. Never touches the system.
@MainActor
private final class ProfileRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]
    func register(_ combo: HotkeyCombo, id: UUID) throws { active[id] = combo }
    func unregister(id: UUID) { active[id] = nil }
    func press(_ id: UUID) { onPress?(id) }
}

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])
private let f7 = HotkeyCombo(keyCode: 98, modifiers: [])
private let f8 = HotkeyCombo(keyCode: 100, modifiers: [])
private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])
private let minecraft = HotkeyAction.profile(.select("Minecraft"))

/// A center on its own temporary folder, hotkeys on, starting from a new install's ⌘1–⌘5.
@MainActor
private final class ProfileCenterHarness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hotkey-profile-center-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store: SettingsStore
    let registrar = ProfileRegistrar()
    var presses: [[HotkeyEvent]] = []
    var center: HotkeyCenter!

    init() {
        store = SettingsStore(directory: directory, debounce: .milliseconds(1))
        store.registerHotkeysExactly()
        store.save(HotkeySettings(isEnabled: true, bindings: HotkeyKeySet.command.bindings()))
        center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] },
                              handler: { [unowned self] in presses.append($0) })
    }

    /// "⌘1 Crosshair", as the Hotkeys page lists a hotkey.
    var listing: [String] { center.bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" } }

    isolated deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Profile hotkeys in the center (spec 6.1): what a press sends, a profile's own key, and the calls a page that lists
/// the profiles can make.
@MainActor
@Suite("Profile hotkeys in the center")
struct HotkeyProfileCenterTests {
    // MARK: A press

    /// The profile comes last in its press, after the tools, the recording and Start timer.
    @Test func aPressSendsTheProfileLast() {
        let h = ProfileCenterHarness()
        let id = h.center.add(combo: f6, actions: [minecraft, .startTimer, .toggle(.crosshair)])
        h.registrar.press(id)
        #expect(h.presses == [[.setTool(.crosshair, isOn: true), .startTimer, .switchProfile(.select("Minecraft"))]])
    }

    @Test func aProfileAloneSendsOnlyTheProfile() {
        let h = ProfileCenterHarness()
        let id = h.center.add(combo: f6, actions: [.profile(.next)])
        #expect(h.center.status(of: id) == .registered)
        h.registrar.press(id)
        #expect(h.presses == [[.switchProfile(.next)]])
    }

    /// An edit keeps one profile action too, the first.
    @Test func anEditKeepsOneProfileAction() {
        let h = ProfileCenterHarness()
        let id = h.center.add(combo: f6, actions: [.toggle(.crosshair)])
        h.center.update(id, actions: [.profile(.next), minecraft, .toggle(.crosshair)])
        #expect(h.center.bindings.first { $0.id == id }?.actions == [.profile(.next), .toggle(.crosshair)])
    }

    // MARK: One key of its own

    /// Switching to a profile has one key of its own, as a tool does: a second hotkey for it alone asks first, and
    /// Replace gives the first one the new key, in its place.
    @Test func aSecondKeyForAProfileAsksAndReplaceKeepsOne() throws {
        let h = ProfileCenterHarness()
        let own = h.center.add(combo: f6, actions: [minecraft])
        let ownBinding = try #require(h.center.bindings.first { $0.id == own })
        #expect(h.center.ownHotkeyReplaced(bySaving: [minecraft], editing: nil) == ownBinding)
        #expect(h.center.ownHotkeyReplaced(bySaving: [minecraft], editing: own) == nil, "its own key, edited")
        #expect(h.center.ownHotkeyReplaced(bySaving: [.toggle(.crosshair), minecraft], editing: nil) == nil, "with another action")
        #expect(h.center.ownHotkeyReplaced(bySaving: [.profile(.select("Typing"))], editing: nil) == nil, "another profile")

        h.center.replaceOwnHotkey(for: minecraft, with: f7, removing: nil)
        #expect(h.center.bindings.filter { $0.actions == [minecraft] }.map(\.combo) == [f7])
        #expect(h.center.profileHotkey(for: "Minecraft")?.id == own)
        #expect(h.listing.last == "F7 Switch to Minecraft")
    }

    @Test func nextProfileHasOneKeyOfItsOwnToo() throws {
        let h = ProfileCenterHarness()
        let own = h.center.add(combo: f6, actions: [.profile(.next)])
        #expect(h.center.ownHotkeyReplaced(bySaving: [.profile(.next)], editing: nil)?.id == own)
        // Editing another hotkey into Next profile alone asks too, and Replace removes the one edited.
        let other = h.center.add(combo: f8, actions: [.toggle(.crosshair)])
        #expect(h.center.ownHotkeyReplaced(bySaving: [.profile(.next)], editing: other)?.id == own)
        h.center.replaceOwnHotkey(for: .profile(.next), with: f8, removing: other)
        #expect(h.center.bindings.filter { $0.actions == [.profile(.next)] }.map(\.id) == [own])
        #expect(h.center.bindings.first { $0.id == own }?.combo == f8)
        #expect(!h.center.bindings.contains { $0.id == other })
    }

    // MARK: For a page that lists the profiles

    /// The profile's own hotkey, every hotkey that switches to it, and setting, moving and removing the own one. Other
    /// hotkeys never move, and the tools' own keep their places.
    @Test func aPageCanFindSetAndClearAProfilesHotkey() throws {
        let h = ProfileCenterHarness()
        #expect(h.center.profileHotkey(for: "Minecraft") == nil)
        let shared = h.center.add(combo: ctrlOptC, actions: [.toggle(.crosshair), minecraft])

        h.center.setProfileHotkey(f6, for: "Minecraft")
        let own = try #require(h.center.profileHotkey(for: "Minecraft"))
        #expect(own.combo == f6 && own.actions == [minecraft])
        #expect(h.center.hotkeys(switchingTo: "Minecraft").map(\.id) == [shared, own.id])
        #expect(h.center.hotkeys(switchingTo: "Typing").isEmpty)
        #expect(h.listing == ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop",
                              "⌘6 Custom Cursor", "⌃⌥C Crosshair + Switch to Minecraft", "F6 Switch to Minecraft"])

        h.center.setProfileHotkey(f7, for: "Minecraft")
        #expect(h.center.profileHotkey(for: "Minecraft")?.id == own.id, "it keeps its id")
        #expect(h.center.profileHotkey(for: "Minecraft")?.combo == f7)
        #expect(h.center.status(of: own.id) == .registered)

        h.center.setProfileHotkey(nil, for: "Minecraft")
        #expect(h.center.profileHotkey(for: "Minecraft") == nil)
        #expect(h.center.hotkeys(switchingTo: "Minecraft").map(\.id) == [shared], "the shared hotkey stays")
        #expect(h.center.keySet == .command)
    }
}
