import Foundation
import Testing
@testable import STPlatform

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])
private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])

/// A hotkey can switch the Key Rebinder's Karabiner profile (spec 6.1): to one profile by name, or to the next one in
/// Karabiner's order. The tools' actions stay what they were: `allCases`, the key sets and the toggle rule ignore it.
@Suite("Profile actions")
struct HotkeyProfileActionTests {
    // MARK: Stored as plain strings

    @Test func storedAsPlainStrings() throws {
        let actions: [HotkeyAction] = [.profile(.select("Minecraft")), .profile(.next)]
        let data = try JSONEncoder().encode(actions)
        #expect(String(decoding: data, as: UTF8.self) == #"["selectProfile.Minecraft","nextProfile"]"#)
        #expect(try JSONDecoder().decode([HotkeyAction].self, from: data) == actions)
    }

    /// A profile's name is the only identity Karabiner-Elements gives it, so it is stored whole, whatever it holds.
    @Test func anyNameRoundTrips() throws {
        for name in ["Default profile", "Any% Glitchless", "a.b.c", "selectProfile.x", "toggle.crosshair", " spaced ",
                     "Q\u{2019}s \u{201C}keys\u{201D}", "日本語", ""] {
            let data = try JSONEncoder().encode([HotkeyAction.profile(.select(name))])
            #expect(try JSONDecoder().decode([HotkeyAction].self, from: data) == [.profile(.select(name))], "\(name)")
        }
    }

    /// A build from before profile actions reads each stored action by its exact name, or by `toggle.` and a tool's name.
    /// No profile action is written that way, whatever the profile is called, so such a build drops it from its hotkey
    /// (lossy decoding) and never reads it as a tool's action.
    @Test func olderBuildsCantReadAProfileActionAsAToolsAction() throws {
        let olderNames: Set<String> = ["startStopRecording", "toggle.screenRecording", "startTimer"]
        for action in [HotkeyAction.profile(.next), .profile(.select("crosshair")), .profile(.select("toggle.crosshair")),
                       .profile(.select("startTimer"))] {
            let text = try JSONDecoder().decode([String].self, from: JSONEncoder().encode([action]))[0]
            #expect(!text.hasPrefix("toggle."), "\(text)")
            #expect(!olderNames.contains(text), "\(text)")
        }
    }

    // MARK: Not a tool's action

    @Test func theToolsActionsStayTheSix() {
        #expect(HotkeyAction.allCases.count == 6)
        #expect(!HotkeyAction.allCases.contains { $0.profileAction != nil })
        #expect(HotkeyKeySet.toolActions == HotkeyAction.allCases)
    }

    @Test func eachActionSaysWhetherItIsAProfileAction() {
        #expect(HotkeyAction.profile(.select("P")).profileAction == .select("P"))
        #expect(HotkeyAction.profile(.next).profileAction == .next)
        #expect(HotkeyAction.toggle(.crosshair).profileAction == nil)
        #expect(HotkeyAction.startTimer.profileAction == nil)
    }

    // MARK: One profile action per hotkey

    /// A hotkey switches to one profile, so it keeps the first profile action and drops the rest, as it drops repeats.
    @Test func aHotkeyKeepsOneProfileActionTheFirst() {
        let binding = HotkeyBinding(combo: f6, actions: [.profile(.select("A")), .toggle(.crosshair), .profile(.next),
                                                         .profile(.select("B")), .toggle(.crosshair)])
        #expect(binding.actions == [.profile(.select("A")), .toggle(.crosshair)])
        #expect(binding.profileAction == .select("A"))
        #expect(HotkeyBinding(combo: f6, actions: [.toggle(.crosshair)]).profileAction == nil)
    }

    @Test func decodingKeepsOneProfileActionToo() throws {
        let json = """
        {"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F","combo":{"keyCode":97,"modifiers":0},
         "actions":["nextProfile","toggle.crosshair","selectProfile.A","nextProfile"]}
        """
        let binding = try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        #expect(binding.actions == [.profile(.next), .toggle(.crosshair)])
    }

    /// The editors save the tools' actions in sidebar order, then the profile action.
    @Test func theEditorsOrderPutsTheProfileLast() {
        let chosen: [HotkeyAction] = [.profile(.select("P")), .toggle(.windowBackdrop), .toggle(.crosshair), .profile(.next)]
        #expect(HotkeyAction.pickerOrder(chosen) == [.toggle(.crosshair), .toggle(.windowBackdrop), .profile(.select("P"))])
        #expect(HotkeyAction.pickerOrder(Set<HotkeyAction>([.startTimer, .toggle(.crosshair)])) == [.toggle(.crosshair), .startTimer])
        #expect(HotkeyAction.pickerOrder([HotkeyAction.profile(.next)]) == [.profile(.next)])
        #expect(HotkeyAction.pickerOrder([HotkeyAction]()).isEmpty)
    }

    // MARK: A press

    @Test func aPressCarriesTheProfileAction() {
        #expect(HotkeyAction.resolve([.profile(.select("P"))], toolStates: [:])
            == HotkeyOutcome(toolChanges: [], togglesRecording: false, profile: .select("P")))
        #expect(HotkeyAction.resolve([.toggle(.crosshair)], toolStates: [:]).profile == nil)
    }

    /// The profile never takes part in the toggle rule: the tools beside it follow the rule without it.
    @Test func theProfileNeverTakesPartInTheToggleDecision() {
        for crosshairIsOn in [false, true] {
            let outcome = HotkeyAction.resolve([.profile(.next), .toggle(.crosshair)], toolStates: [.crosshair: crosshairIsOn])
            #expect(outcome.toolChanges == [HotkeyToolChange(tool: .crosshair, isOn: !crosshairIsOn)])
            #expect(outcome.profile == .next)
        }
    }

    @Test func aSetWithSeveralProfileActionsSwitchesToTheFirst() {
        #expect(HotkeyAction.resolve([.profile(.select("B")), .profile(.next)], toolStates: [:]).profile == .select("B"))
    }
}

/// `hotkeys.json` keeps version 3: a profile action is a new action string, which a build from before it drops from its
/// hotkey, and a version 4 would make that build set the whole list aside instead.
@MainActor
@Suite("Profile actions in hotkeys.json")
struct HotkeyProfileFileTests {
    /// A folder of its own holding `hotkeys.json`, removed afterwards.
    @MainActor
    private final class Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: "hotkey-profiles-\(UUID().uuidString)", directoryHint: .isDirectory)

        init(_ text: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        var file: URL { url.appending(path: "hotkeys.json") }

        /// A plain store, so it writes nothing that `hotkeys.json` doesn't ask for.
        func store() -> SettingsStore { SettingsStore(directory: url, debounce: .milliseconds(1)) }

        func text() throws -> String { try String(contentsOf: file, encoding: .utf8) }

        /// The file's JSON, to compare with what was written whatever its layout.
        func json() throws -> NSDictionary {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary)
        }

        isolated deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// One stored hotkey, as `hotkeys.json` holds it.
    private static func entry(_ id: String, keyCode: Int, modifiers: Int = 256, _ actions: [String]) -> String {
        let names = actions.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"actions":[\#(names)],"combo":{"keyCode":\#(keyCode),"modifiers":\#(modifiers)},"id":"00000000-0000-0000-0000-0000000000\#(id)"}"#
    }

    /// ducky's list in a version 3 file: ⌘1 Crosshair, ⌘2 Start timer, ⌘3 NBB Overlay, ⌘4 Screen Recording, ⌘5 Window
    /// Backdrop, hotkeys on, in sTools and Minecraft, with the confirmation; then `extra` hotkeys.
    private static func version3File(extra: [String] = []) -> String {
        let own = [entry("C1", keyCode: 18, ["toggle.crosshair"]), entry("C2", keyCode: 19, ["startTimer"]),
                   entry("C3", keyCode: 20, ["toggle.nbbOverlay"]), entry("C4", keyCode: 21, ["startStopRecording"]),
                   entry("C5", keyCode: 23, ["toggle.windowBackdrop"])]
        let bindings = (own + extra).joined(separator: ",")
        return #"{"value":{"bindings":[\#(bindings)],"isEnabled":true,"scope":"sToolsAndMinecraft","showsConfirmation":true},"version":3}"#
    }

    /// F6 switches to the profile Minecraft; ⌃⌥C switches Crosshair and goes to the next profile.
    private static let profileHotkeys = [
        entry("D1", keyCode: 97, modifiers: 0, ["selectProfile.Minecraft"]),
        entry("D2", keyCode: 8, modifiers: 6144, ["toggle.crosshair", "nextProfile"]),
    ]

    @Test func theFileStaysAtVersionThree() {
        #expect(HotkeySettings.version == 3)
    }

    /// ducky's version 3 file loads unchanged, keys, actions, ids and order, and nothing writes it back. Written before
    /// Custom Cursor, it has no key for it, so it follows no key set until one is picked.
    @Test func aVersionThreeFileLoadsUnchangedAndIsntWritten() async throws {
        let folder = try Folder(Self.version3File())
        let store = folder.store()
        let center = HotkeyCenter(store: store, registrar: QuietRegistrar(), toolStates: { [:] }, handler: { _ in })
        #expect(center.bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
            == ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"])
        #expect(center.bindings.map { String($0.id.uuidString.suffix(2)) } == ["C1", "C2", "C3", "C4", "C5"])
        #expect(center.keySet == nil)
        #expect(center.isEnabled && center.showsConfirmation && center.scope == .sToolsAndMinecraft)
        #expect(center.bindings.allSatisfy { $0.profileAction == nil })
        await store.flush()
        #expect(store.writeCount == 0)
        #expect(try folder.text() == Self.version3File())
    }

    /// Hotkeys with profile actions load as they are, and nothing writes them back at launch. Saving the list writes them
    /// as they were read, in their places, and the file reads back to the same list.
    @Test func profileActionsRoundTrip() async throws {
        let folder = try Folder(Self.version3File(extra: Self.profileHotkeys))
        let before = try folder.json()
        let store = folder.store()
        let center = HotkeyCenter(store: store, registrar: QuietRegistrar(), toolStates: { [:] }, handler: { _ in })
        #expect(center.bindings.suffix(2).map(\.actions) == [[.profile(.select("Minecraft"))], [.toggle(.crosshair), .profile(.next)]])
        #expect(center.bindings.map { String($0.id.uuidString.suffix(2)) } == ["C1", "C2", "C3", "C4", "C5", "D1", "D2"])
        await store.flush()
        #expect(store.writeCount == 0, "loading wrote the file")

        // A change elsewhere writes the list back: it is the same JSON, profile actions and all.
        center.showsConfirmation = false
        await store.flush()
        center.showsConfirmation = true
        await store.flush()
        #expect(store.writeCount == 2)
        #expect(try folder.json() == before)
        #expect(folder.store().load(HotkeySettings.self).bindings == center.bindings)
    }
}

/// Registers nothing with the system.
@MainActor
private final class QuietRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    func register(_ combo: HotkeyCombo, id: UUID) throws {}
    func unregister(id: UUID) {}
}
