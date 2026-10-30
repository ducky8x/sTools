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
private let secondRecordingID = "00000000-0000-0000-0000-0000000000C7"
private let thirdRecordingID = "00000000-0000-0000-0000-0000000000C8"

/// One stored hotkey, as `hotkeys.json` holds it.
private func entry(_ id: String, keyCode: Int, modifiers: Int = 256, _ actions: [String]) -> String {
    let names = actions.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":"\#(id)","combo":{"keyCode":\#(keyCode),"modifiers":\#(modifiers)},"actions":[\#(names)]}"#
}

/// ducky's own list, set by hand before key sets existed: ⌘1 Crosshair, ⌘2 Start timer, ⌘3 NBB Overlay, ⌘4 Screen
/// Recording (under any name an earlier build wrote), ⌘5 Window Backdrop. It is also the ⌘1–⌘5 key set in today's
/// sidebar order.
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

/// "⌘1 Crosshair", as Home lists a hotkey.
private func listing(_ bindings: [HotkeyBinding]) -> [String] {
    bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
}

private let sidebarOrder = ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"]
/// Build 449's ⌘1–⌘5, in the sidebar order it had.
private let build449Order = ["⌘1 NBB Overlay", "⌘2 Window Backdrop", "⌘3 Crosshair", "⌘4 Start timer", "⌘5 Screen Recording"]
private let ownIDs = [crosshairID, timerID, nbbID, recordingID, backdropID]

/// A folder of its own holding one `hotkeys.json`, removed afterwards.
@MainActor
private final class Folder {
    let url = FileManager.default.temporaryDirectory.appending(path: "hotkey-migration-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(_ text: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url.appending(path: "hotkeys.json"))
    }

    var store: SettingsStore {
        let store = SettingsStore(directory: url, debounce: .milliseconds(1))
        store.registerHotkeysExactly()
        return store
    }

    func load() -> HotkeySettings { store.load(HotkeySettings.self) }

    /// The file as stored: its version and its value.
    func stored() throws -> (version: Int?, value: [String: Any]) {
        let data = try Data(contentsOf: url.appending(path: "hotkeys.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (root["version"] as? Int, root["value"] as? [String: Any] ?? [:])
    }

    isolated deinit { try? FileManager.default.removeItem(at: url) }
}

/// Version 2 of `hotkeys.json` (spec 6.1): the empty list earlier builds started people with becomes the ⌘1–⌘5 key set
/// in sidebar order, once. A list with hotkeys in it, ducky's included, is never moved.
@MainActor
@Suite("Hotkey list migration")
struct HotkeyMigrationTests {
    @Test func theFileIsAtVersionThree() {
        #expect(HotkeySettings.version == 3)
    }

    // MARK: ducky's list stays exactly as it is

    /// ducky's list loads unchanged, keys, actions, ids and order, and the Key set chooser shows ⌘1–⌘5, because the key
    /// set in sidebar order is that list. The switches and the scope stay too.
    @Test func duckysListLoadsUnchangedAsCommandOneToFive() throws {
        let folder = try Folder(file(oldList()))
        let settings = folder.load()
        #expect(listing(settings.bindings) == sidebarOrder)
        #expect(settings.bindings.map(\.id.uuidString) == ownIDs)
        #expect(settings.bindings == HotkeyKeySet.command.bindings().enumerated().map { index, binding in
            HotkeyBinding(id: UUID(uuidString: ownIDs[index])!, combo: binding.combo, actions: binding.actions)
        }, "it is the ⌘1–⌘5 key set")
        #expect(HotkeyKeySet.current(in: settings.bindings) == .command)
        #expect(settings.isEnabled)
        #expect(settings.showsConfirmation)
        #expect(settings.scope == .sToolsAndMinecraft)
    }

    /// F13–F17 was a key set until spec revision 26. A list on those keys (F13 Crosshair, F14 Start timer, F15 NBB
    /// Overlay, F16 Screen Recording, F17 Window Backdrop) loads unchanged, keys, actions, ids and order, whatever its
    /// version, and the Key set chooser shows Custom.
    @Test func aListOnF13ToF17LoadsUnchangedAsCustom() async throws {
        let fKeys = [105, 107, 113, 106, 64]
        let actions = [["toggle.crosshair"], ["startTimer"], ["toggle.nbbOverlay"], ["startStopRecording"], ["toggle.windowBackdrop"]]
        let entries = (0..<5).map { entry(ownIDs[$0], keyCode: fKeys[$0], modifiers: 0, actions[$0]) }
        let fOrder = ["F13 Crosshair", "F14 Start timer", "F15 NBB Overlay", "F16 Screen Recording", "F17 Window Backdrop"]
        for version in [1, 2, 3] {
            let settings = try Folder(file(version: version, entries)).load()
            #expect(listing(settings.bindings) == fOrder, "version \(version)")
            #expect(settings.bindings.map(\.id.uuidString) == ownIDs, "version \(version)")
            #expect(HotkeyKeySet.current(in: settings.bindings) == nil, "version \(version)")
            #expect(HotkeyKeySet.name(of: HotkeyKeySet.current(in: settings.bindings)) == "Custom")
        }

        let folder = try Folder(file(version: 3, entries))
        let store = folder.store
        let registrar = MigrationRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        #expect(listing(center.bindings) == fOrder)
        #expect(center.keySet == nil)
        #expect(Set(registrar.active.values.map(\.displayString)) == ["F13", "F14", "F15", "F16", "F17"])
        await store.flush()
        let stored = try folder.stored()
        #expect((stored.value["bindings"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ownIDs)
    }

    /// Earlier builds wrote Screen Recording's key as "Toggle Screen Recording", "Start/stop recording" or both: each
    /// reads as the one action, on the same key, in the same place.
    @Test func everyNameEarlierBuildsGaveScreenRecordingKeepsTheList() throws {
        for recording in [["startStopRecording"], ["toggle.screenRecording"], ["toggle.screenRecording", "startStopRecording"],
                          ["startStopRecording", "toggle.screenRecording"]] {
            let settings = try Folder(file(oldList(recording: recording))).load()
            #expect(listing(settings.bindings) == sidebarOrder, "\(recording)")
            #expect(settings.bindings.map(\.id.uuidString) == ownIDs, "\(recording)")
        }
    }

    /// The same five keys in another order keep that order: nothing reorders a list someone has. It still follows the
    /// ⌘1–⌘5 key set, which looks only at each tool's key.
    @Test func theSameFiveKeysInAnotherOrderKeepThatOrder() throws {
        let settings = try Folder(file(oldList().reversed())).load()
        #expect(listing(settings.bindings) == sidebarOrder.reversed())
        #expect(settings.bindings.map(\.id.uuidString) == ownIDs.reversed())
        #expect(HotkeyKeySet.current(in: settings.bindings) == .command)
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

    // MARK: Build 449's move is undone

    /// Build 449's ⌘1–⌘5 default, as its version 2 file holds it.
    private var build449Entries: [String] {
        [entry(nbbID, keyCode: 18, ["toggle.nbbOverlay"]), entry(backdropID, keyCode: 19, ["toggle.windowBackdrop"]),
         entry(crosshairID, keyCode: 20, ["toggle.crosshair"]), entry(timerID, keyCode: 21, ["startTimer"]),
         entry(recordingID, keyCode: 23, ["startStopRecording"])]
    }

    /// Build 449 moved ducky's list to its own sidebar order as it launched (⌘1 NBB Overlay … ⌘5 Screen Recording) and
    /// wrote it as version 2. That exact list moves back to the ⌘1–⌘5 key set, which is ducky's list again: the same
    /// keys, ids and order as before 449. The switches and the scope stay.
    @Test func build449sListMovesBackToDuckysKeys() throws {
        let settings = try Folder(file(version: 2, build449Entries, isEnabled: false,
                                       extra: #","showsConfirmation":false,"scope":"everywhere""#)).load()
        #expect(listing(settings.bindings) == sidebarOrder)
        #expect(settings.bindings.map(\.id.uuidString) == ownIDs, "each tool keeps its id")
        #expect(HotkeyKeySet.current(in: settings.bindings) == .command)
        #expect(!settings.isEnabled)
        #expect(!settings.showsConfirmation)
        #expect(settings.scope == .everywhere)
        // In any order, and with Screen Recording under its former name.
        let reversed = try Folder(file(version: 2, build449Entries.reversed().map {
            $0.replacingOccurrences(of: "startStopRecording", with: "toggle.screenRecording")
        })).load()
        #expect(listing(reversed.bindings) == sidebarOrder)
        #expect(reversed.bindings.map(\.id.uuidString) == ownIDs)
    }

    /// Only a version 2 file moves: the same list in a version 1 file was set by hand (no build wrote it), so it stays
    /// as it is and reads as Custom. ducky's own version 1 list never takes part either.
    @Test func aVersionOneFileInBuild449sOrderStaysAsItIs() throws {
        let settings = try Folder(file(version: 1, build449Entries)).load()
        #expect(listing(settings.bindings) == build449Order)
        #expect(settings.bindings.map(\.id.uuidString) == [nbbID, backdropID, crosshairID, timerID, recordingID])
        #expect(HotkeyKeySet.current(in: settings.bindings) == nil)
    }

    /// Anything but build 449's exact list stays as it is in a version 2 file: a changed key, an extra hotkey, another
    /// modifier, a hotkey with two actions, one missing.
    @Test func aChangedBuild449ListStaysAsItIs() throws {
        var oneKeyChanged = build449Entries
        oneKeyChanged[0] = entry(nbbID, keyCode: 97, modifiers: 0, ["toggle.nbbOverlay"])
        let extra = build449Entries + [entry(secondRecordingID, keyCode: 8, modifiers: 6144, ["toggle.crosshair", "toggle.nbbOverlay"])]
        let control = build449Entries.map { $0.replacingOccurrences(of: #""modifiers":256"#, with: #""modifiers":4096"#) }
        var twoActions = build449Entries
        twoActions[0] = entry(nbbID, keyCode: 18, ["toggle.nbbOverlay", "toggle.crosshair"])
        let oneMissing = Array(build449Entries.dropLast())
        for (name, entries) in [("one key changed", oneKeyChanged), ("an extra hotkey", extra), ("⌃ instead of ⌘", control),
                                ("two actions", twoActions), ("one missing", oneMissing)] {
            let raw = try JSONDecoder().decode(HotkeySettings.self, from: Data(#"{"isEnabled":true,"bindings":[\#(entries.joined(separator: ","))]}"#.utf8))
            #expect(try Folder(file(version: 2, entries)).load().bindings == raw.bindings, "\(name)")
        }
    }

    /// The center writes the moved list back as version 3 as it starts, so it happens once; afterwards build 449's
    /// order, set again by hand, stays.
    @Test func theCenterWritesTheMoveBackOnce() async throws {
        let folder = try Folder(file(version: 2, build449Entries))
        let store = folder.store
        let center = HotkeyCenter(store: store, registrar: MigrationRegistrar(), toolStates: { [:] }, handler: { _ in })
        #expect(listing(center.bindings) == sidebarOrder)
        await store.flush()
        #expect(try folder.stored().version == 3)
        #expect(listing(try Folder(file(version: 3, build449Entries)).load().bindings) == build449Order)
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

    /// Once a file is version 2 or later, its list is the person's own: the old order, or no hotkeys at all (the None key set),
    /// stays as it is.
    @Test func aVersionTwoFileIsNeverMigrated() throws {
        for version in [2, 3] {
            #expect(listing(try Folder(file(version: version, oldList())).load().bindings) == sidebarOrder)
            #expect(try Folder(file(version: version, [])).load().bindings.isEmpty)
            #expect(listing(try Folder(file(version: version, oldList().reversed())).load().bindings) == sidebarOrder.reversed())
        }
    }

    // MARK: Screen Recording's two former keys become one

    /// Builds with two Screen Recording actions could leave a key for each, "Toggle Screen Recording" and "Start/stop
    /// recording". Both are the one action now, so a list keeps one key for it, whatever the file's version: Home never
    /// lists Screen Recording twice. Without a key set's key among them, the first in the list stays, with its id and
    /// its place; every other hotkey stays as it is.
    @Test func aKeyForEachFormerScreenRecordingActionBecomesOne() throws {
        let toggleKey = entry(recordingID, keyCode: 15, modifiers: 2048, ["toggle.screenRecording"]) // ⌥R
        let crosshairKey = entry(crosshairID, keyCode: 8, modifiers: 6144, ["toggle.crosshair", "toggle.nbbOverlay"]) // ⌃⌥C
        let startStopKey = entry(secondRecordingID, keyCode: 22, ["startStopRecording"]) // ⌘6
        for version in [1, 2] {
            let settings = try Folder(file(version: version, [toggleKey, crosshairKey, startStopKey])).load()
            #expect(listing(settings.bindings) == ["⌥R Screen Recording", "⌃⌥C Crosshair + NBB Overlay"], "version \(version)")
            #expect(settings.bindings.map(\.id.uuidString) == [recordingID, crosshairID], "version \(version)")
        }
    }

    /// The key a key set gives Screen Recording (⌘4 in ⌘1–⌘5, or ⌃4, ⌥4) stays wherever it is in the list, so a list
    /// that follows a key set keeps following it; without one, the key an earlier build's key set gave it (⌘5, ⌃5, ⌥5,
    /// F17) stays.
    @Test func theKeySetsScreenRecordingKeyIsTheOneThatStays() throws {
        let f6Toggle = entry(recordingID, keyCode: 97, modifiers: 0, ["toggle.screenRecording"])
        let commandFive = entry(secondRecordingID, keyCode: 23, ["startStopRecording"])
        let settings = try Folder(file(version: 2, [f6Toggle, commandFive])).load()
        #expect(listing(settings.bindings) == ["⌘5 Screen Recording"])
        #expect(settings.bindings.map(\.id.uuidString) == [secondRecordingID])

        let controlFive = entry(secondRecordingID, keyCode: 23, modifiers: 4096, ["toggle.screenRecording"])
        let f6StartStop = entry(recordingID, keyCode: 97, modifiers: 0, ["startStopRecording"])
        #expect(listing(try Folder(file(version: 2, [f6StartStop, controlFive])).load().bindings) == ["⌃5 Screen Recording"])

        let commandFour = entry(thirdRecordingID, keyCode: 21, ["toggle.screenRecording"])
        let both = try Folder(file(version: 2, [f6Toggle, commandFive, commandFour])).load()
        #expect(listing(both.bindings) == ["⌘4 Screen Recording"], "today's key set wins over an earlier one's")
        #expect(both.bindings.map(\.id.uuidString) == [thirdRecordingID])
    }

    /// F16, the key the removed F13–F17 key set gave Screen Recording, still stays as a key set's key does, so a list
    /// that followed that set loads with the keys it had; F17, that set's key in an earlier sidebar order, stays like
    /// the other earlier keys.
    @Test func theRemovedFunctionKeySetsScreenRecordingKeyStillStays() throws {
        let f16 = entry(recordingID, keyCode: 106, modifiers: 0, ["startStopRecording"])
        let f17 = entry(secondRecordingID, keyCode: 64, modifiers: 0, ["toggle.screenRecording"])
        let f6 = entry(thirdRecordingID, keyCode: 97, modifiers: 0, ["toggle.screenRecording"])
        let commandFive = entry(thirdRecordingID, keyCode: 23, ["startStopRecording"])

        let f16AndF17 = try Folder(file(version: 2, [f17, f16])).load()
        #expect(listing(f16AndF17.bindings) == ["F16 Screen Recording"])
        #expect(f16AndF17.bindings.map(\.id.uuidString) == [recordingID])
        #expect(listing(try Folder(file(version: 2, [commandFive, f16])).load().bindings) == ["F16 Screen Recording"],
                "F16 wins over an earlier key set's key")
        #expect(listing(try Folder(file(version: 2, [f6, f17])).load().bindings) == ["F17 Screen Recording"],
                "F17 wins over a key set by hand")

        let commandFour = entry(secondRecordingID, keyCode: 21, ["startStopRecording"])
        #expect(listing(try Folder(file(version: 2, [f16, commandFour])).load().bindings) == ["F16 Screen Recording"],
                "between F16 and a key set's key, the first in the list stays")
    }

    /// Three keys that only record become one too, and a hotkey that records together with other things isn't one of
    /// them: it stays, and so does the one Screen Recording key beside it.
    @Test func onlyHotkeysThatOnlyRecordAreMerged() throws {
        let entries = [entry(recordingID, keyCode: 97, modifiers: 0, ["startStopRecording"]),
                       entry(crosshairID, keyCode: 8, modifiers: 6144, ["toggle.crosshair", "startStopRecording"]),
                       entry(secondRecordingID, keyCode: 98, modifiers: 0, ["toggle.screenRecording", "startStopRecording"]),
                       entry(thirdRecordingID, keyCode: 100, modifiers: 0, ["toggle.screenRecording"])]
        let settings = try Folder(file(version: 2, entries)).load()
        #expect(listing(settings.bindings) == ["F6 Screen Recording", "⌃⌥C Crosshair + Screen Recording"])

        let one = [entry(recordingID, keyCode: 23, ["startStopRecording"]),
                   entry(crosshairID, keyCode: 8, modifiers: 6144, ["toggle.crosshair", "toggle.screenRecording"])]
        #expect(listing(try Folder(file(version: 2, one)).load().bindings) == ["⌘5 Screen Recording", "⌃⌥C Crosshair + Screen Recording"])
    }

    /// ducky's list with a second key for Screen Recording (its other former action, on ⌘6) keeps ⌘4, the key set's,
    /// and is ducky's list again.
    @Test func duckysListWithASecondScreenRecordingKeyKeepsCommandFour() throws {
        let folder = try Folder(file(oldList() + [entry(secondRecordingID, keyCode: 22, ["toggle.screenRecording"])]))
        let settings = folder.load()
        #expect(listing(settings.bindings) == sidebarOrder)
        #expect(settings.bindings.map(\.id.uuidString) == ownIDs)
        #expect(HotkeyKeySet.current(in: settings.bindings) == .command)
    }

    /// The center writes the one key back with the rest of the move to version 2, so the file holds what Home shows.
    @Test func theCenterWritesTheOneScreenRecordingKeyBack() async throws {
        let entries = [entry(recordingID, keyCode: 15, modifiers: 2048, ["toggle.screenRecording"]),
                       entry(secondRecordingID, keyCode: 22, ["startStopRecording"])]
        let folder = try Folder(file(entries))
        let store = folder.store
        let registrar = MigrationRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        #expect(listing(center.bindings) == ["⌥R Screen Recording"])
        #expect(registrar.active.count == 1)
        await store.flush()
        let stored = try folder.stored()
        #expect(stored.version == 3)
        #expect((stored.value["bindings"] as? [Any])?.count == 1)
    }

    // MARK: Once

    /// The center writes ducky's list back as version 2 as it starts, unchanged, and registers its keys at once.
    @Test func theCenterWritesDuckysListBackUnchanged() async throws {
        let folder = try Folder(file(oldList()))
        let store = folder.store
        let registrar = MigrationRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        #expect(listing(center.bindings) == sidebarOrder)
        #expect(center.keySet == .command)
        #expect(Set(registrar.active.values) == Set(HotkeyKeySet.command.combos))
        await store.flush()

        let stored = try folder.stored()
        #expect(stored.version == 3)
        #expect(stored.value["isEnabled"] as? Bool == true)
        #expect((stored.value["bindings"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ownIDs)
        let relaunched = HotkeyCenter(store: folder.store, registrar: MigrationRegistrar(), toolStates: { [:] }, handler: { _ in })
        #expect(relaunched.bindings == center.bindings)
    }

    /// A current file isn't written again at launch, and neither is the option's file: nothing is written until
    /// something changes. The store is a plain one, with Also fire while holding Shift or Control as it starts out.
    @Test func aCurrentFileIsntRewritten() async throws {
        let folder = try Folder(file(version: 3, oldList()))
        let store = SettingsStore(directory: folder.url, debounce: .milliseconds(1))
        _ = HotkeyCenter(store: store, registrar: MigrationRegistrar(), toolStates: { [:] }, handler: { _ in })
        await store.flush()
        #expect(store.writeCount == 0)
    }

    /// A list someone changed is only brought up to version 3, as it is.
    @Test func aChangedListIsWrittenBackAsItIs() async throws {
        var entries = oldList()
        entries[1] = entry(timerID, keyCode: 22, ["startTimer"])
        let folder = try Folder(file(entries))
        let store = folder.store
        let center = HotkeyCenter(store: store, registrar: MigrationRegistrar(), toolStates: { [:] }, handler: { _ in })
        await store.flush()
        #expect(try folder.stored().version == 3)
        #expect(listing(center.bindings) == ["⌘1 Crosshair", "⌘6 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"])
        #expect(folder.load().bindings == center.bindings)
    }
}
