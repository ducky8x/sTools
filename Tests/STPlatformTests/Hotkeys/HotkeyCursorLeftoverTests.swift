import Foundation
import Testing
@testable import STPlatform

/// Earlier builds had a seventh tool, Custom Cursor, with its own toggle, `toggle.cursor`, on ⌘6 in a key set. That
/// tool is now part of the Crosshair, so a `hotkeys.json` they saved still loads: the action is dropped as any
/// action this build doesn't know is, and every other hotkey keeps its key, actions, id and place.
@MainActor
@Suite("Hotkeys: a list saved with Custom Cursor's toggle")
struct HotkeyCursorLeftoverTests {
    private func entry(_ id: Int, keyCode: Int, _ actions: [String]) -> String {
        let names = actions.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":"00000000-0000-0000-0000-0000000000F\#(id)","combo":{"keyCode":\#(keyCode),"modifiers":256},"actions":[\#(names)]}"#
    }

    /// ⌘1–⌘6 as their key set gave it, plus ⌘C for the Crosshair and Custom Cursor together.
    private var savedList: String {
        let entries = [
            entry(1, keyCode: 18, ["toggle.crosshair"]), entry(2, keyCode: 19, ["startTimer"]),
            entry(3, keyCode: 20, ["toggle.nbbOverlay"]), entry(4, keyCode: 21, ["startStopRecording"]),
            entry(5, keyCode: 23, ["toggle.windowBackdrop"]), entry(6, keyCode: 22, ["toggle.cursor"]),
            entry(7, keyCode: 8, ["toggle.crosshair", "toggle.cursor"]),
        ]
        return #"{"version":3,"value":{"isEnabled":true,"bindings":[\#(entries.joined(separator: ","))]}}"#
    }

    @Test func theToggleIsNoActionThisBuildKnows() {
        #expect(HotkeyTool(rawValue: "cursor") == nil)
        #expect(HotkeyTool.allCases == [.crosshair, .nbbOverlay, .windowBackdrop])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([HotkeyAction].self, from: Data(#"["toggle.cursor"]"#.utf8)) }
    }

    @Test func aSavedListLoadsWithoutIt() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hotkey-cursor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(savedList.utf8).write(to: url.appending(path: "hotkeys.json"))

        let store = SettingsStore(directory: url, debounce: .milliseconds(1))
        let loaded = store.load(HotkeySettings.self)
        #expect(loaded.isEnabled)
        #expect(loaded.bindings.map { String($0.id.uuidString.suffix(2)) } == ["F1", "F2", "F3", "F4", "F5", "F6", "F7"])
        #expect(loaded.bindings.map(\.combo.displayString) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘C"])
        #expect(loaded.bindings.map(\.actions) == [
            [.toggle(.crosshair)], [.startTimer], [.toggle(.nbbOverlay)], [.startStopRecording], [.toggle(.windowBackdrop)], [],
            [.toggle(.crosshair)],
        ])
        // The tools' own keys are ⌘1–⌘5 again, so the list follows that set.
        #expect(HotkeyKeySet.current(in: loaded.bindings) == .command)
        #expect(HotkeyKeySet.command.title == "⌘1–⌘5")
        // Nothing moved the file aside or wrote it back: it's still the one that build saved.
        #expect(store.storedVersion(HotkeySettings.self) == 3)
        #expect(try String(contentsOf: url.appending(path: "hotkeys.json"), encoding: .utf8) == savedList)
    }
}
