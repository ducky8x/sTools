import Foundation

/// `hotkeys.json` version 1 to 2 (spec 6.1, revision 9): a list an earlier build left someone with, rather than one
/// they made, becomes the key set a new install has, ⌘1–⌘5 in sidebar order. It runs once: `HotkeyCenter` writes the
/// result back as version 2, and from then on the list is the person's own.
///
/// Two lists count, matched by their hotkeys (key and actions) whatever their order and ids:
/// - no hotkeys at all, every build's list before key sets existed;
/// - the ⌘1–⌘5 list in the old order: ⌘1 Crosshair, ⌘2 Start timer, ⌘3 NBB Overlay, ⌘4 Screen Recording (under any
///   name an earlier build wrote it), ⌘5 Window Backdrop, each alone on its key.
///
/// Anything else is kept exactly as it is: a changed key, an extra or missing hotkey, another modifier, a hotkey with
/// more than one action, an action this build doesn't know, or an entry it can't read. The other settings (the master
/// switch, the confirmation, Where hotkeys work) are never touched. Each tool keeps its hotkey's id.
///
/// Before the match, a list's keys for Screen Recording alone become one (`withOneScreenRecordingKey`), as they do
/// whenever a list loads: so the old list with a key for each of Screen Recording's two former actions still counts.
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

    private static let command = HotkeyCombo.Modifiers.command

    /// The lists earlier builds left people with.
    private static let earlierLists: [Set<Entry>] = [
        [],
        [Entry(combo: HotkeyCombo(keyCode: 18, modifiers: command), actions: [.toggle(.crosshair)]),
         Entry(combo: HotkeyCombo(keyCode: 19, modifiers: command), actions: [.startTimer]),
         Entry(combo: HotkeyCombo(keyCode: 20, modifiers: command), actions: [.toggle(.nbbOverlay)]),
         Entry(combo: HotkeyCombo(keyCode: 21, modifiers: command), actions: [.startStopRecording]),
         Entry(combo: HotkeyCombo(keyCode: 23, modifiers: command), actions: [.toggle(.windowBackdrop)])],
    ]

    /// The version 1 value `raw` as version 2: its `bindings` replaced by the new install's key set when they are one of
    /// `earlierLists`, else `raw` unchanged.
    static func upgrade(_ raw: [String: Any]) -> [String: Any] {
        guard let stored = raw["bindings"] as? [Any], let strict = read(stored) else { return raw }
        let hotkeys = withOneScreenRecordingKey(strict.map { HotkeyBinding(id: $0.id, combo: $0.combo, actions: $0.actions) })
        let entries = hotkeys.map { Entry(combo: $0.combo, actions: $0.actions) }
        let found = Set(entries)
        guard found.count == entries.count, earlierLists.contains(found) else { return raw }

        // Each tool keeps the id its hotkey had; a tool that had none gets a new one.
        var ids: [HotkeyAction: UUID] = [:]
        for hotkey in hotkeys where hotkey.actions.count == 1 { ids[hotkey.actions[0]] = hotkey.id }
        let bindings = HotkeyKeySet.newInstall.bindings().map { binding in
            HotkeyBinding(id: binding.actions.first.flatMap { ids[$0] } ?? binding.id, combo: binding.combo, actions: binding.actions)
        }
        guard let data = try? JSONEncoder().encode(bindings),
              let upgraded = try? JSONSerialization.jsonObject(with: data) else { return raw }
        var result = raw
        result["bindings"] = upgraded
        return result
    }

    /// `bindings` with one hotkey whose only action is Screen Recording's. Builds with two Screen Recording actions,
    /// "Toggle Screen Recording" and "Start/stop recording", could leave a key for each; both read as the one action
    /// now (`HotkeyAction`'s decoding), so without this Home would list Screen Recording twice. The one that stays is
    /// the first on the key a key set gives Screen Recording (⌘5, ⌃5, ⌥5 or F17), so a list that follows a key set
    /// keeps following it, else the first in the list; it keeps its id, key and place. Hotkeys that record together with
    /// other things, and every other hotkey, stay as they are. Applied to every list that loads (`HotkeySettings`'
    /// decoding), whatever its version.
    static func withOneScreenRecordingKey(_ bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        let recording = HotkeyAction.startStopRecording
        let indices = bindings.indices.filter { bindings[$0].actions == [recording] }
        guard indices.count > 1 else { return bindings }
        let keySetKeys = Set(HotkeyKeySet.allCases.compactMap { $0.combo(for: recording) })
        let kept = indices.first { keySetKeys.contains(bindings[$0].combo) } ?? indices[0]
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
