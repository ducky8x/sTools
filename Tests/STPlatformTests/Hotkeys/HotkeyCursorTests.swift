import Foundation
import Testing
@testable import STPlatform

/// Custom Cursor's hotkey (spec 5.7.4): a toggle, sixth in the sidebar's order, and ⌘6, ⌃6 or ⌥6 when a key set is picked.
/// A saved list keeps its keys: nothing adds ⌘6 to it.
@MainActor
@Suite("Hotkeys: Custom Cursor")
struct HotkeyCursorTests {
    private let cursor = HotkeyAction.toggle(.cursor)

    private func folder(_ text: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hotkey-cursor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let text { try Data(text.utf8).write(to: url.appending(path: "hotkeys.json")) }
        return url
    }

    @Test func itIsStoredAsTheCursorsToggle() throws {
        #expect(HotkeyTool.cursor.rawValue == "cursor")
        let data = try JSONEncoder().encode([cursor])
        #expect(String(decoding: data, as: UTF8.self) == #"["toggle.cursor"]"#)
        #expect(try JSONDecoder().decode([HotkeyAction].self, from: data) == [cursor])
    }

    @Test func itIsTheSixthToolsAction() {
        #expect(HotkeyAction.allCases.last == cursor)
        #expect(HotkeyAction.allCases.count == 6)
        #expect(HotkeyWording.summary([cursor]) == "Custom Cursor")
    }

    @Test func eachKeySetGivesItTheSixthKey() {
        let six: UInt16 = 22
        #expect(HotkeyKeySet.command.combo(for: cursor) == HotkeyCombo(keyCode: six, modifiers: .command))
        #expect(HotkeyKeySet.control.combo(for: cursor) == HotkeyCombo(keyCode: six, modifiers: .control))
        #expect(HotkeyKeySet.option.combo(for: cursor) == HotkeyCombo(keyCode: six, modifiers: .option))
        #expect(HotkeyKeySet.noKeys.combo(for: cursor) == nil)
        #expect(HotkeyKeySet.command.combo(for: cursor)?.displayString == "⌘6")
    }

    /// A press toggles it like the other overlays.
    @Test func aPressSwitchesItLikeAnyToggle() {
        #expect(HotkeyAction.resolve([cursor], toolStates: [.cursor: false]).toolChanges == [HotkeyToolChange(tool: .cursor, isOn: true)])
        #expect(HotkeyAction.resolve([cursor], toolStates: [.cursor: true]).toolChanges == [HotkeyToolChange(tool: .cursor, isOn: false)])
    }

    /// ducky's ⌘1–⌘5, written before Custom Cursor, loads with the same keys, ids and order, still version 3, and gains
    /// no ⌘6. With no key for Custom Cursor it follows no set, so the chooser says Custom until a set is picked.
    @Test func aSavedListKeepsItsKeysAndGainsNoSixthKey() throws {
        let ids = (1...5).map { "00000000-0000-0000-0000-0000000000C\($0)" }
        let names = ["toggle.crosshair", "startTimer", "toggle.nbbOverlay", "startStopRecording", "toggle.windowBackdrop"]
        let keys = [18, 19, 20, 21, 23]
        let entries = (0..<5).map { #"{"id":"\#(ids[$0])","combo":{"keyCode":\#(keys[$0]),"modifiers":256},"actions":["\#(names[$0])"]}"# }
        let url = try folder(#"{"version":3,"value":{"isEnabled":true,"bindings":[\#(entries.joined(separator: ","))]}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(directory: url, debounce: .milliseconds(1))
        let loaded = store.load(HotkeySettings.self)
        #expect(loaded.bindings.map(\.id.uuidString) == ids)
        #expect(loaded.bindings.map(\.combo.displayString) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"])
        #expect(!loaded.bindings.contains { $0.actions.contains(cursor) })
        #expect(HotkeyKeySet.current(in: loaded.bindings) == nil)
        #expect(HotkeySettings.version == 3)

        // Picking ⌘1–⌘6 then adds ⌘6 for Custom Cursor and changes nothing else; there's nothing to ask about.
        #expect(HotkeyKeySet.command.replacedEdits(in: loaded.bindings).isEmpty)
        let picked = HotkeyKeySet.command.applied(to: loaded.bindings)
        #expect(Array(picked.prefix(5)) == loaded.bindings)
        #expect(picked.last?.combo.displayString == "⌘6")
        #expect(picked.last?.actions == [cursor])
        #expect(HotkeyKeySet.current(in: picked) == .command)
    }

    /// A build without Custom Cursor drops `toggle.cursor` from its hotkey and keeps the rest of the list, as it does for
    /// profile actions, so the file stays at version 3.
    @Test func anActionThisBuildDoesntKnowIsDroppedAlone() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-0000000000D1","combo":{"keyCode":22,"modifiers":256},"actions":["toggle.someday","toggle.crosshair"]}]"#
        let bindings = try JSONDecoder().decode([HotkeyBinding].self, from: Data(json.utf8))
        #expect(bindings.map(\.actions) == [[.toggle(.crosshair)]])
    }

    /// A new install starts with ⌘1–⌘6, Custom Cursor's ⌘6 last.
    @Test func aNewInstallStartsWithCommandOneToSix() throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = SettingsStore(directory: url).load(HotkeySettings.self)
        #expect(loaded.bindings.map(\.combo.displayString) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6"])
        #expect(loaded.bindings.last?.actions == [cursor])
    }

    /// Build 449's list moves back to ducky's own five keys, and only those: no ⌘6 joins them.
    @Test func undoingBuild449GivesBackTheFiveKeysAlone() throws {
        let entries = [(18, "toggle.nbbOverlay"), (19, "toggle.windowBackdrop"), (20, "toggle.crosshair"), (21, "startTimer"),
                       (23, "startStopRecording")].enumerated().map { index, pair in
            #"{"id":"00000000-0000-0000-0000-0000000000E\#(index)","combo":{"keyCode":\#(pair.0),"modifiers":256},"actions":["\#(pair.1)"]}"#
        }
        let url = try folder(#"{"version":2,"value":{"isEnabled":true,"bindings":[\#(entries.joined(separator: ","))]}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = SettingsStore(directory: url).load(HotkeySettings.self)
        #expect(loaded.bindings.map(\.combo.displayString) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"])
        #expect(loaded.bindings.map(\.actions) == [[.toggle(.crosshair)], [.startTimer], [.toggle(.nbbOverlay)], [.startStopRecording],
                                                   [.toggle(.windowBackdrop)]])
    }
}
