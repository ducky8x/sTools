import STDesign
import STPlatform
import ScreenRecording
import SwiftUI
import TimerOverlay

extension ToolID {
    /// The tool a hotkey toggles; nil for the tools a hotkey doesn't toggle: Screen Recording and Timer Overlay, whose
    /// one action each switches them on (`hotkeyAction`), and the Key Rebinder, which has no switch.
    var hotkeyTool: HotkeyTool? {
        switch self {
        case .nbbOverlay: .nbbOverlay
        case .windowBackdrop: .windowBackdrop
        case .crosshair: .crosshair
        case .screenRecording, .timerOverlay, .keyRebinder: nil
        }
    }

    /// The tool's one hotkey action (spec 6.1): the toggle of the three overlay tools, Screen Recording's start/stop,
    /// Timer Overlay's Start timer. Nil for the Key Rebinder, which sets hotkeys on its keys instead. A key set's hotkey
    /// for the tool does this action too (Home ▸ Hotkeys ▸ Key set, `HotkeyKeySet.toolActions`).
    var hotkeyAction: HotkeyAction? {
        switch self {
        case .screenRecording: .startStopRecording
        case .timerOverlay: .startTimer
        default: hotkeyTool.map(HotkeyAction.toggle)
        }
    }
}

/// A tool's own hotkey in the app's one list (`HotkeyCenter`, spec 6.1): the first hotkey whose only action is the
/// tool's action (`ToolID.hotkeyAction`). The tool page's Hotkey row sets, changes and clears it; Home ▸ Hotkeys and
/// the Key Rebinder show the same hotkey.
@MainActor
enum ToolHotkey {
    static func own(for action: HotkeyAction, in bindings: [HotkeyBinding]) -> HotkeyBinding? {
        HotkeyKeySet.ownBinding(for: action, in: bindings)
    }

    /// The other hotkeys with the tool's action: together with something else, or alone on another key. Screen
    /// Recording never has a second key alone: a list's keys for its two former actions become one as it loads
    /// (`HotkeySettings`).
    static func shared(for action: HotkeyAction, in bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        let own = own(for: action, in: bindings)
        return bindings.filter { $0.actions.contains(action) && $0.id != own?.id }
    }

    /// Sets the tool's own hotkey to `combo`: changes its key, or adds it in its sidebar place among the tools' own
    /// hotkeys, which Home lists first. Nil clears it.
    static func set(_ combo: HotkeyCombo?, for action: HotkeyAction, in center: HotkeyCenter) {
        center.setOwnHotkey(combo, for: action)
    }

    /// Why the row refuses `combo` while recording, with the same rules as Home's editor: another hotkey has it, macOS
    /// keeps it, or sTools doesn't know the key. Nil when it's fine.
    static func refusal(for combo: HotkeyCombo, action: HotkeyAction, in center: HotkeyCenter) -> String? {
        let own = own(for: action, in: center.bindings)
        guard let conflict = center.conflict(for: combo, excluding: own?.id), conflict != .noActions else { return nil }
        return HotkeyWording.conflictText(conflict, combo: combo, inList: false)
    }

    /// "Also: ⌃⌥C (Crosshair + NBB Overlay)." for the other hotkeys with the tool's action; nil when none.
    static func sharedText(for action: HotkeyAction, in bindings: [HotkeyBinding]) -> String? {
        let shared = shared(for: action, in: bindings)
        guard !shared.isEmpty else { return nil }
        return "Also: " + shared.map { "\($0.combo.displayString) (\(HotkeyWording.summary($0.actions)))" }.joined(separator: ", ") + "."
    }
}

/// A tool page's Hotkey row, near the top (spec 6.1): the key for the tool's one action (it toggles an overlay tool,
/// starts and stops Screen Recording, or starts the timer), set, changed or cleared right here by pressing a key
/// (Delete clears, Esc cancels). Under it, Timer Overlay's and Screen Recording's one line on what the key does, what's
/// wrong with that key, the notes both hotkey editors show, the other hotkeys that do the tool's action, where hotkeys
/// work and the key set with Change… (Home ▸ Hotkeys), and, while hotkeys are off, Turn On.
struct ToolHotkeyRow: View {
    let model: AppModel
    let tool: ToolID
    let action: HotkeyAction
    @Environment(\.stTheme) private var theme

    init?(model: AppModel, tool: ToolID) {
        guard let action = tool.hotkeyAction else { return nil }
        self.model = model
        self.tool = tool
        self.action = action
    }

    private var hotkeys: HotkeyCenter { model.hotkeys }

    var body: some View {
        let own = ToolHotkey.own(for: action, in: hotkeys.bindings)
        VStack(alignment: .leading, spacing: 6) {
            STSettingsRow("Hotkey", showsRule: false) {
                STShortcutRecorder(shortcut: shortcutBinding, label: "\(tool.title) hotkey",
                                   validate: { ToolHotkey.refusal(for: $0.hotkeyCombo, action: action, in: hotkeys) })
                    .frame(width: 200)
            }
            if let purposeLine {
                caption(purposeLine)
            }
            if let problemNote {
                Text(problemNote)
                    .stStyle(.caption)
                    .foregroundStyle(STColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let own {
                ForEach(Array(hotkeys.notes(for: own.combo).enumerated()), id: \.offset) { _, note in
                    STNoteLine(note)
                }
            }
            if let shared = ToolHotkey.sharedText(for: action, in: hotkeys.bindings) {
                caption(shared)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                caption(whereLine)
                Button("Change\u{2026}") { changeWhereHotkeysWork() }
                    .buttonStyle(STButtonStyle(.quiet))
                    .accessibilityLabel("Change where hotkeys work and the key set")
            }
            if !hotkeys.isEnabled, own != nil || ToolHotkey.sharedText(for: action, in: hotkeys.bindings) != nil {
                HStack(spacing: 12) {
                    caption("Hotkeys are off. Turn them on to use this key.")
                    Button("Turn On") { model.hotkeys.isEnabled = true }
                        .buttonStyle(STButtonStyle(.quiet))
                        .accessibilityLabel("Turn on hotkeys")
                }
            }
        }
    }

    /// What's wrong with the tool's own key, in red under the row; nil when nothing is. A page isn't Home's list, so a
    /// key another hotkey has gets the words for outside it: nothing on a tool page is "above".
    var problemNote: String? {
        guard let own = ToolHotkey.own(for: action, in: hotkeys.bindings) else { return nil }
        return HotkeyWording.statusNote(hotkeys.status(of: own.id), combo: own.combo, inList: false)
    }

    /// Where hotkeys work and the key set the tools follow, as Home ▸ Hotkeys sets them: "Hotkeys work in sTools and
    /// Minecraft · Key set: ⌘1–⌘5", or only in sTools while Accessibility is missing, as Home says.
    var whereLine: String {
        HotkeyWording.whereAndKeySet(scope: hotkeys.scope, keySet: hotkeys.keySet,
                                     accessibilityGranted: model.accessibilityGranted)
    }

    /// What the key does, where a page needs to say more than its title: Timer Overlay's key starts the timer, and its
    /// cancel gesture switches the tool off; Screen Recording's one key starts and stops a recording, asks Save or
    /// Delete, and the stop switches the tool off. Nil for the overlay tools, whose key just toggles them.
    var purposeLine: String? {
        switch tool {
        case .timerOverlay: TimerKeyLine.text(for: model.timerOverlay?.settings.cancelGesture ?? .doublePress)
        case .screenRecording:
            Self.screenRecordingPurpose(asksSaveOrDelete: model.controller(
                for: .screenRecording, as: ScreenRecordingController.self)?.options.askSaveDelete ?? true)
        default: nil
        }
    }

    /// Screen Recording's line under its Hotkey row (spec 5.4.4, 6.1), following its Advanced setting
    /// Ask Save or Delete on stop.
    static func screenRecordingPurpose(asksSaveOrDelete: Bool) -> String {
        asksSaveOrDelete
            ? "Starts a recording; press again to stop, name it and Save or Delete. Stopping switches Screen Recording off."
            : "Starts a recording; press again to stop and save it under its date and time. Stopping switches Screen Recording off."
    }

    /// Change…: Home ▸ Hotkeys, where both are set.
    func changeWhereHotkeysWork() { model.openHotkeys() }

    private var shortcutBinding: Binding<STShortcut?> {
        Binding(
            get: { ToolHotkey.own(for: action, in: model.hotkeys.bindings)?.combo.asSTShortcut },
            set: { ToolHotkey.set($0?.hotkeyCombo, for: action, in: model.hotkeys) })
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .stStyle(.caption)
            .foregroundStyle(theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
