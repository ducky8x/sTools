import Foundation

/// `hotkeys.json` version 1 to 2 (spec 6.1, revision 9): the list every build before key sets started people with, no
/// hotkeys at all, becomes the key set a new install has, ⌘1–⌘5 in sidebar order. It runs once: `HotkeyCenter` writes
/// the result back as version 2, and from then on the list is the person's own.
///
/// Only that empty list counts. Every list with a hotkey in it is kept exactly as it is, keys, actions, ids and order:
/// ducky's own ⌘1 Crosshair, ⌘2 Start timer, ⌘3 NBB Overlay, ⌘4 Screen Recording, ⌘5 Window Backdrop (which is also
/// the ⌘1–⌘5 key set in today's sidebar order, so it reads as that set), a changed key, an extra or missing hotkey,
/// another modifier, a hotkey with more than one action, an action this build doesn't know, or an entry it can't
/// read. (Revision 10, owner: "the hotkeys stay the same, but the order in the sidebar changes": no build moves a
/// list someone has.) The other settings (the master switch, the confirmation, Where hotkeys work) are never touched.
///
/// Before the match, a list's keys for Screen Recording alone become one (`withOneScreenRecordingKey`), as they do
/// whenever a list loads.
enum HotkeyListUpgrade {
    /// One hotkey of a stored list, without its id.
    private struct Entry: Hashable {
        let combo: HotkeyCombo
        let actions: [HotkeyAction]
    }

    /// One stored hotkey, read strictly: an id that isn't a UUID, a combo that can't be read or an action name this build
    /// doesn't know fails it, and with it the match.
    private struct StoredHotkey: Decodable {
        let id: UUID
        let combo: HotkeyCombo
        let actions: [HotkeyAction]
    }

    /// The lists earlier builds left people with, rather than ones they made: no hotkeys at all.
    private static let earlierLists: [Set<Entry>] = [[]]

    /// The version 1 value `raw` as version 2: its `bindings` replaced by the new install's key set when they are one of
    /// `earlierLists`, else `raw` unchanged.
    static func upgrade(_ raw: [String: Any]) -> [String: Any] {
        guard let stored = raw["bindings"] as? [Any], let strict = read(stored) else { return raw }
        let hotkeys = withOneScreenRecordingKey(strict.map { HotkeyBinding(id: $0.id, combo: $0.combo, actions: $0.actions) })
        let entries = hotkeys.map { Entry(combo: $0.combo, actions: $0.actions) }
        let found = Set(entries)
        guard found.count == entries.count, earlierLists.contains(found) else { return raw }

        let bindings = HotkeyKeySet.newInstall.bindings()
        guard let data = try? JSONEncoder().encode(bindings),
              let upgraded = try? JSONSerialization.jsonObject(with: data) else { return raw }
        var result = raw
        result["bindings"] = upgraded
        return result
    }

    // MARK: Version 2 to 3

    /// The key the version 1 to 2 step leaves in a file that started at version 1, so the next step leaves its list
    /// alone; the next step removes it, so it is never stored.
    private static let fromVersionOneKey = "upgradedFromVersion1"

    /// `raw`, as the version 1 to 2 step leaves it, marked for `undoingBuild449` to pass over.
    static func markedAsFromVersionOne(_ raw: [String: Any]) -> [String: Any] {
        var result = raw
        result[fromVersionOneKey] = true
        return result
    }

    /// Build 449's ⌘1–⌘5 list, in its sidebar order: ⌘1 NBB Overlay, ⌘2 Window Backdrop, ⌘3 Crosshair, ⌘4 Start timer,
    /// ⌘5 Screen Recording.
    private static let build449List: Set<Entry> = {
        let command = HotkeyCombo.Modifiers.command
        return [Entry(combo: HotkeyCombo(keyCode: 18, modifiers: command), actions: [.toggle(.nbbOverlay)]),
                Entry(combo: HotkeyCombo(keyCode: 19, modifiers: command), actions: [.toggle(.windowBackdrop)]),
                Entry(combo: HotkeyCombo(keyCode: 20, modifiers: command), actions: [.toggle(.crosshair)]),
                Entry(combo: HotkeyCombo(keyCode: 21, modifiers: command), actions: [.startTimer]),
                Entry(combo: HotkeyCombo(keyCode: 23, modifiers: command), actions: [.startStopRecording])]
    }()

    /// Version 2 to 3 (revision 10; ducky: "the hotkeys stay the same, but the order in the sidebar changes"). Build 449
    /// moved ducky's own list (⌘1 Crosshair, ⌘2 Start timer, ⌘3 NBB Overlay, ⌘4 Screen Recording, ⌘5 Window Backdrop)
    /// to its sidebar order and wrote it as version 2. A version 2 list that is exactly build 449's, matched by key and
    /// actions whatever its order, goes back to the ⌘1–⌘5 key set in today's sidebar order, which is ducky's list: each
    /// tool keeps its hotkey's id, so ducky gets back the same keys, ids and order. Anything else stays as it is, and
    /// so does every list from a file that was version 1 on disk (marked by `markedAsFromVersionOne`): nothing wrote
    /// build 449's order there, so it is someone's own.
    static func undoingBuild449(_ raw: [String: Any]) -> [String: Any] {
        var raw = raw
        if raw.removeValue(forKey: fromVersionOneKey) != nil { return raw }
        guard let stored = raw["bindings"] as? [Any], let strict = read(stored) else { return raw }
        let hotkeys = withOneScreenRecordingKey(strict.map { HotkeyBinding(id: $0.id, combo: $0.combo, actions: $0.actions) })
        let entries = hotkeys.map { Entry(combo: $0.combo, actions: $0.actions) }
        guard Set(entries).count == entries.count, Set(entries) == build449List else { return raw }

        var ids: [HotkeyAction: UUID] = [:]
        for hotkey in hotkeys { ids[hotkey.actions[0]] = hotkey.id }
        let bindings = HotkeyKeySet.command.bindings().map { binding in
            HotkeyBinding(id: ids[binding.actions[0]] ?? binding.id, combo: binding.combo, actions: binding.actions)
        }
        guard let data = try? JSONEncoder().encode(bindings),
              let moved = try? JSONSerialization.jsonObject(with: data) else { return raw }
        raw["bindings"] = moved
        return raw
    }

    // MARK: Screen Recording's keys

    /// The keys earlier builds' key sets gave Screen Recording, fifth in their sidebar order: ⌘5, ⌃5, ⌥5 and F17
    /// (the F13–F17 key set's, removed since).
    private static let earlierKeySetRecordingKeys: Set<HotkeyCombo> = [
        HotkeyCombo(keyCode: 23, modifiers: .command), HotkeyCombo(keyCode: 23, modifiers: .control),
        HotkeyCombo(keyCode: 23, modifiers: .option), HotkeyCombo(keyCode: 64, modifiers: []),
    ]

    /// The key the F13–F17 key set gave Screen Recording in today's sidebar order, F16, before that set was removed
    /// (spec revision 26). A list on F13–F17 reads as Custom now; F16 still wins here as it did, so such a list loads
    /// with the keys it had.
    private static let removedKeySetRecordingKeys: Set<HotkeyCombo> = [HotkeyCombo(keyCode: 106, modifiers: [])]

    /// `bindings` with one hotkey whose only action is Screen Recording's. Builds with two Screen Recording actions,
    /// "Toggle Screen Recording" and "Start/stop recording", could leave a key for each; both read as the one action
    /// now (`HotkeyAction`'s decoding), so without this Home would list Screen Recording twice. The one that stays is
    /// the first on the key a key set gives Screen Recording (⌘4, ⌃4 or ⌥4) or the removed F13–F17 set gave it (F16),
    /// so a list that follows a key set keeps following it, else the first on the key an earlier build's key set gave
    /// it (⌘5, ⌃5, ⌥5 or F17), else the first in the list; it keeps its id, key and place. Hotkeys that record
    /// together with other things, and every other hotkey, stay as they are. Applied to every list that loads
    /// (`HotkeySettings`' decoding), whatever its version.
    static func withOneScreenRecordingKey(_ bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        let recording = HotkeyAction.startStopRecording
        let indices = bindings.indices.filter { bindings[$0].actions == [recording] }
        guard indices.count > 1 else { return bindings }
        let keySetKeys = Set(HotkeyKeySet.allCases.compactMap { $0.combo(for: recording) }).union(removedKeySetRecordingKeys)
        let kept = indices.first { keySetKeys.contains(bindings[$0].combo) }
            ?? indices.first { earlierKeySetRecordingKeys.contains(bindings[$0].combo) }
            ?? indices[0]
        let dropped = Set(indices).subtracting([kept])
        return bindings.indices.filter { !dropped.contains($0) }.map { bindings[$0] }
    }

    /// Every stored hotkey, or nil when any of them can't be read strictly.
    private static func read(_ stored: [Any]) -> [StoredHotkey]? {
        guard JSONSerialization.isValidJSONObject(stored),
              let data = try? JSONSerialization.data(withJSONObject: stored) else { return nil }
        return try? JSONDecoder().decode([StoredHotkey].self, from: data)
    }
}
