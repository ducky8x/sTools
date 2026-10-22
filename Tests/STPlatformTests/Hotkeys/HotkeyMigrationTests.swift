import Foundation
import Testing
@testable import STPlatform

/// Registers nothing with the system; only records what is registered.
@MainActor
private final class MigrationRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]
    func register(_ combo: HotkeyCombo, id: UUID) throws { active[id] = combo }
    func unregister(id: UUID) { active[id] = nil }
}

private let crosshairID = "00000000-0000-0000-0000-0000000000C1"
private let timerID = "00000000-0000-0000-0000-0000000000C2"
private let nbbID = "00000000-0000-0000-0000-0000000000C3"
private let recordingID = "00000000-0000-0000-0000-0000000000C4"
private let backdropID = "00000000-0000-0000-0000-0000000000C5"

/// One stored hotkey, as `hotkeys.json` holds it.
private func entry(_ id: String, keyCode: Int, modifiers: Int = 256, _ actions: [String]) -> String {
    let names = actions.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":"\#(id)","combo":{"keyCode":\#(keyCode),"modifiers":\#(modifiers)},"actions":[\#(names)]}"#
}

/// The list earlier builds left ducky with, set by hand in the old order: ⌘1 Crosshair, ⌘2 Start timer, ⌘3 NBB
/// Overlay, ⌘4 Screen Recording (under any name an earlier build wrote), ⌘5 Window Backdrop.
private func oldList(recording: [String] = ["startStopRecording"]) -> [String] {
    [entry(crosshairID, keyCode: 18, ["toggle.crosshair"]),
     entry(timerID, keyCode: 19, ["startTimer"]),
     entry(nbbID, keyCode: 20, ["toggle.nbbOverlay"]),
     entry(recordingID, keyCode: 21, recording),
     entry(backdropID, keyCode: 23, ["toggle.windowBackdrop"])]
}

private func file(version: Int = 1, _ entries: [String], isEnabled: Bool = true, extra: String = #","showsConfirmation":true"#) -> String {
    #"{"version":\#(version),"value":{"isEnabled":\#(isEnabled)\#(extra),"bindings":[\#(entries.joined(separator: ","))]}}"#
}

/// "⌘1 NBB Overlay", as Home lists a hotkey.
private func listing(_ bindings: [HotkeyBinding]) -> [String] {
    bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
}

private let sidebarOrder = ["⌘1 NBB Overlay", "⌘2 Window Backdrop", "⌘3 Crosshair", "⌘4 Start timer", "⌘5 Screen Recording"]
private let oldOrder = ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"]

/// A folder of its own holding one `hotkeys.json`, removed afterwards.
@MainActor
private final class Folder {
    let url = FileManager.default.temporaryDirectory.appending(path: "hotkey-migration-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(_ text: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url.appending(path: "hotkeys.json"))
    }

    var store: SettingsStore { SettingsStore(directory: url, debounce: .milliseconds(1)) }

    func load() -> HotkeySettings { store.load(HotkeySettings.self) }

    /// The file as stored: its version and its value.
    func stored() throws -> (version: Int?, value: [String: Any]) {
        let data = try Data(contentsOf: url.appending(path: "hotkeys.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (root["version"] as? Int, root["value"] as? [String: Any] ?? [:])
    }

    isolated deinit { try? FileManager.default.removeItem(at: url) }
}

/// Version 2 of `hotkeys.json` (spec 6.1): a list earlier builds started people with becomes the ⌘1–⌘5 key set in
/// sidebar order, once. A list anyone changed stays as it is.
@MainActor
@Suite("Hotkey list migration")
struct HotkeyMigrationTests {
    @Test func theFileIsAtVersionTwo() {
        #expect(HotkeySettings.version == 2)
    }

    // MARK: The old list becomes the sidebar-order key set

    /// ducky's list, set by hand before key sets existed, reads ⌘1 to ⌘5 in sidebar order afterwards, and the Key set
    /// chooser shows ⌘1–⌘5 instead of Custom. Each tool keeps its hotkey's id; the switches and the scope stay.
    @Test func theOldListBecomesCommandOneToFiveInSidebarOrder() throws {
        let folder = try Folder(file(oldList()))
        let settings = folder.load()
        #expect(listing(settings.bindings) == sidebarOrder)
        #expect(settings.bindings.map(\.id.uuidString) == [nbbID, backdropID, crosshairID, timerID, recordingID])
        #expect(HotkeyKeySet.current(in: settings.bindings) == .command)
        #expect(settings.isEnabled)
        #expect(settings.showsConfirmation)
        #expect(settings.scope == .sToolsAndMinecraft)
    }

    /// Earlier builds wrote Screen Recording's key as "Toggle Screen Recording", "Start/stop recording" or both.
    @Test func everyNameEarlierBuildsGaveScreenRecordingCounts() throws {
        for recording in [["startStopRecording"], ["toggle.screenRecording"], ["toggle.screenRecording", "startStopRecording"],
                          ["startStopRecording", "toggle.screenRecording"]] {
            let folder = try Folder(file(oldList(recording: recording)))
            #expect(listing(folder.load().bindings) == sidebarOrder, "\(recording)")
        }
    }

    /// The list's own order never counted for anything a person chose: the same five keys in any order migrate.
    @Test func theSameFiveKeysInAnyOrderCount() throws {
        let folder = try Folder(file(oldList().reversed()))
        let settings = folder.load()
        #expect(listing(settings.bindings) == sidebarOrder)
        #expect(settings.bindings.map(\.id.uuidString) == [nbbID, backdropID, crosshairID, timerID, recordingID])
    }

    /// The flags come through as they were: off stays off, and so do Everywhere and a hidden confirmation.
    @Test func theSwitchesAndWhereHotkeysWorkStay() throws {
        let folder = try Folder(file(oldList(), isEnabled: false, extra: #","showsConfirmation":false,"scope":"everywhere""#))
        let settings = folder.load()
        #expect(listing(settings.bindings) == sidebarOrder)
        #expect(!settings.isEnabled)
        #expect(!settings.showsConfirmation)
        #expect(settings.scope == .everywhere)
    }

    /// Earlier builds started everyone with no hotkeys at all: that list becomes a new install's ⌘1–⌘5 too, with the
    /// master switch as it was.
    @Test func theEarlierEmptyListBecomesCommandOneToFive() throws {
        for isEnabled in [true, false] {
            let folder = try Folder(file([], isEnabled: isEnabled))
            let settings = folder.load()
            #expect(listing(settings.bindings) == sidebarOrder)
            #expect(settings.isEnabled == isEnabled)
            #expect(Set(settings.bindings.map(\.id)).count == 5)
        }
    }

    // MARK: Lists anyone changed stay as they are

    @Test func aChangedListStaysAsItIs() throws {
        var oneKeyChanged = oldList()
        oneKeyChanged[1] = entry(timerID, keyCode: 22, ["startTimer"]) // ⌘6
        var extraHotkey = oldList()
        extraHotkey.append(entry("00000000-0000-0000-0000-0000000000C6", keyCode: 8, modifiers: 6144, ["toggle.crosshair", "toggle.nbbOverlay"]))
        let anotherMapping = [entry(nbbID, keyCode: 18, ["toggle.nbbOverlay"]),
                              entry(crosshairID, keyCode: 19, ["toggle.crosshair"]),
                              entry(timerID, keyCode: 20, ["startTimer"]),
                              entry(recordingID, keyCode: 21, ["startStopRecording"]),
                              entry(backdropID, keyCode: 23, ["toggle.windowBackdrop"])]
        let controlInsteadOfCommand = oldList().map { $0.replacingOccurrences(of: #""modifiers":256"#, with: #""modifiers":4096"#) }
        var multiAction = oldList()
        multiAction[0] = entry(crosshairID, keyCode: 18, ["toggle.crosshair", "toggle.nbbOverlay"])
        var unknownAction = oldList()
        unknownAction[0] = entry(crosshairID, keyCode: 18, ["toggle.crosshair", "someFutureAction"])
        let oneMissing = Array(oldList().dropLast())
        var oneBroken = oldList()
        oneBroken[4] = entry("not-a-uuid", keyCode: 23, ["toggle.windowBackdrop"])

        let cases: [(String, [String])] = [
            ("one key changed", oneKeyChanged), ("an extra hotkey", extraHotkey), ("another mapping", anotherMapping),
            ("⌃ instead of ⌘", controlInsteadOfCommand), ("a hotkey with two actions", multiAction),
            ("an action this build doesn't know", unknownAction), ("one missing", oneMissing), ("one unreadable", oneBroken),
        ]
        for (name, entries) in cases {
            let folder = try Folder(file(entries))
            let raw = try JSONDecoder().decode(HotkeySettings.self, from: Data(#"{"isEnabled":true,"bindings":[\#(entries.joined(separator: ","))]}"#.utf8))
            #expect(folder.load().bindings == raw.bindings, "\(name)")
        }
    }

    /// The key set a new install has, already in sidebar order, needs nothing.
    @Test func theNewKeySetIsKeptAsItIs() throws {
        let entries = [entry(nbbID, keyCode: 18, ["toggle.nbbOverlay"]), entry(backdropID, keyCode: 19, ["toggle.windowBackdrop"]),
                       entry(crosshairID, keyCode: 20, ["toggle.crosshair"]), entry(timerID, keyCode: 21, ["startTimer"]),
                       entry(recordingID, keyCode: 23, ["startStopRecording"])]
        let settings = try Folder(file(entries)).load()
        #expect(listing(settings.bindings) == sidebarOrder)
        #expect(settings.bindings.map(\.id.uuidString) == [nbbID, backdropID, crosshairID, timerID, recordingID])
    }

    /// Once a file is version 2, its list is the person's own: the old order, or no hotkeys at all (the None key set),
    /// stays as it is.
    @Test func aVersionTwoFileIsNeverMigrated() throws {
        #expect(listing(try Folder(file(version: 2, oldList())).load().bindings) == oldOrder)
        #expect(try Folder(file(version: 2, [])).load().bindings.isEmpty)
    }

    // MARK: Once

    /// The center writes the upgraded list back as version 2 as it starts, so the migration runs once, and registers
    /// the new keys at once.
    @Test func theCenterWritesTheUpgradeBackOnce() async throws {
        let folder = try Folder(file(oldList()))
        let store = folder.store
        let registrar = MigrationRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        #expect(listing(center.bindings) == sidebarOrder)
        #expect(center.keySet == .command)
        #expect(Set(registrar.active.values) == Set(HotkeyKeySet.command.combos))
        await store.flush()

        let stored = try folder.stored()
        #expect(stored.version == 2)
        #expect(stored.value["isEnabled"] as? Bool == true)
        let relaunched = HotkeyCenter(store: folder.store, registrar: MigrationRegistrar(), toolStates: { [:] }, handler: { _ in })
        #expect(relaunched.bindings == center.bindings)
    }

    /// A current file isn't written again at launch.
    @Test func aCurrentFileIsntRewritten() async throws {
        let folder = try Folder(file(version: 2, oldList()))
        let store = folder.store
        _ = HotkeyCenter(store: store, registrar: MigrationRegistrar(), toolStates: { [:] }, handler: { _ in })
        await store.flush()
        #expect(store.writeCount == 0)
    }

    /// A list someone changed is only brought up to version 2, as it is.
    @Test func aChangedListIsWrittenBackAsItIs() async throws {
        var entries = oldList()
        entries[1] = entry(timerID, keyCode: 22, ["startTimer"])
        let folder = try Folder(file(entries))
        let store = folder.store
        let center = HotkeyCenter(store: store, registrar: MigrationRegistrar(), toolStates: { [:] }, handler: { _ in })
        await store.flush()
        #expect(try folder.stored().version == 2)
        #expect(listing(center.bindings) == ["⌘1 Crosshair", "⌘6 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"])
        #expect(folder.load().bindings == center.bindings)
    }
}
