import STDesign
import STPlatform
import SwiftUI

extension ToolID {
    /// The hotkey action's name for this tool; nil for the Key Rebinder, which has no switch.
    var hotkeyTool: HotkeyTool? {
        switch self {
        case .nbbOverlay: .nbbOverlay
        case .windowBackdrop: .windowBackdrop
        case .crosshair: .crosshair
        case .screenRecording: .screenRecording
        case .keyRebinder: nil
        }
    }
}

/// A tool's own hotkey in the app's one list (`HotkeyCenter`, spec 6.1): the first hotkey whose only action toggles
/// the tool. The tool page's Hotkey row sets, changes and clears it; Home ▸ Hotkeys and the Key Rebinder show the
/// same hotkey.
@MainActor
enum ToolHotkey {
    static func own(for tool: HotkeyTool, in bindings: [HotkeyBinding]) -> HotkeyBinding? {
        bindings.first { $0.actions == [.toggle(tool)] }
    }

    /// The other hotkeys that toggle `tool`, together with something else.
    static func shared(for tool: HotkeyTool, in bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        bindings.filter { $0.actions.contains(.toggle(tool)) && $0.actions != [.toggle(tool)] }
    }

    /// Sets the tool's own hotkey to `combo`: changes its key, or adds it at the end of the list. Nil clears it.
    static func set(_ combo: HotkeyCombo?, for tool: HotkeyTool, in center: HotkeyCenter) {
        let own = own(for: tool, in: center.bindings)
        switch (combo, own) {
        case (let combo?, let own?): center.update(own.id, combo: combo)
        case (let combo?, nil): center.add(combo: combo, actions: [.toggle(tool)])
        case (nil, let own?): center.remove(own.id)
        case (nil, nil): break
        }
    }

    /// Why the row refuses `combo` while recording, with the same rules as Home's editor: another hotkey has it, macOS
    /// keeps it, or sTools doesn't know the key. Nil when it's fine.
    static func refusal(for combo: HotkeyCombo, tool: HotkeyTool, in center: HotkeyCenter) -> String? {
        let own = own(for: tool, in: center.bindings)
        guard let conflict = center.conflict(for: combo, excluding: own?.id), conflict != .noActions else { return nil }
        return HotkeyWording.conflictText(conflict, combo: combo, inList: false)
    }

    /// "Also: ⌃⌥C (Crosshair + NBB Overlay)." for the hotkeys that toggle the tool with other things; nil when none.
    static func sharedText(for tool: HotkeyTool, in bindings: [HotkeyBinding]) -> String? {
        let shared = shared(for: tool, in: bindings)
        guard !shared.isEmpty else { return nil }
        return "Also: " + shared.map { "\($0.combo.displayString) (\(HotkeyWording.summary($0.actions)))" }.joined(separator: ", ") + "."
    }
}

/// A tool page's Hotkey row, near the top (spec 6.1): the key that toggles the tool, set, changed or cleared right here
/// by pressing a key (Delete clears, Esc cancels). Under it, what's wrong with that key, the notes both hotkey editors
/// show, the hotkeys that toggle the tool with other things, and, while hotkeys are off, Turn On.
struct ToolHotkeyRow: View {
    let model: AppModel
    let tool: ToolID
    let hotkeyTool: HotkeyTool
    @Environment(\.stTheme) private var theme

    init?(model: AppModel, tool: ToolID) {
        guard let hotkeyTool = tool.hotkeyTool else { return nil }
        self.model = model
        self.tool = tool
        self.hotkeyTool = hotkeyTool
    }

    private var hotkeys: HotkeyCenter { model.hotkeys }

    var body: some View {
        let own = ToolHotkey.own(for: hotkeyTool, in: hotkeys.bindings)
        VStack(alignment: .leading, spacing: 6) {
            STSettingsRow("Hotkey", showsRule: false) {
                STShortcutRecorder(shortcut: shortcutBinding, label: "\(tool.title) hotkey",
                                   validate: { ToolHotkey.refusal(for: $0.hotkeyCombo, tool: hotkeyTool, in: hotkeys) })
                    .frame(width: 200)
            }
            if let own, let problem = HotkeyWording.statusNote(hotkeys.status(of: own.id), combo: own.combo) {
                Text(problem)
                    .stStyle(.caption)
                    .foregroundStyle(STColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let own {
                ForEach(Array(hotkeys.notes(for: own.combo).enumerated()), id: \.offset) { _, note in
                    STNoteLine(note)
                }
            }
            if let shared = ToolHotkey.sharedText(for: hotkeyTool, in: hotkeys.bindings) {
                caption(shared)
            }
            if !hotkeys.isEnabled, own != nil || ToolHotkey.sharedText(for: hotkeyTool, in: hotkeys.bindings) != nil {
                HStack(spacing: 12) {
                    caption("Hotkeys are off, so this key does nothing yet.")
                    Button("Turn On") { model.hotkeys.isEnabled = true }
                        .buttonStyle(STButtonStyle(.quiet))
                        .accessibilityLabel("Turn on hotkeys")
                }
            }
        }
    }

    private var shortcutBinding: Binding<STShortcut?> {
        Binding(
            get: { ToolHotkey.own(for: hotkeyTool, in: model.hotkeys.bindings)?.combo.asSTShortcut },
            set: { ToolHotkey.set($0?.hotkeyCombo, for: hotkeyTool, in: model.hotkeys) })
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .stStyle(.caption)
            .foregroundStyle(theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
