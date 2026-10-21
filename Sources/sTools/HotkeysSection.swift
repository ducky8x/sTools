import STDesign
import STPlatform
import SwiftUI

/// Home ▸ Hotkeys (spec 6.1): a master switch, the list of bindings, an add/edit editor for each, and
/// Advanced (spec 2.4) with the press confirmation.
struct HotkeysSection: View {
    let model: AppModel
    @State private var editingID: UUID?
    @State private var isAddingNew = false
    @State private var advancedIsOpen: Bool

    init(model: AppModel, advancedIsOpen: Bool = false) {
        self.model = model
        _advancedIsOpen = State(initialValue: advancedIsOpen)
    }

    var body: some View {
        PageSectionTitle("Hotkeys").padding(.top, 28).padding(.bottom, 4)
        STSettingsRow("Hotkeys", showsRule: model.hotkeys.isEnabled) {
            STSwitch(isOn: enabledBinding, label: "Hotkeys")
        }
        if model.hotkeys.isEnabled {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.hotkeys.bindings) { binding in
                    HotkeyBindingRow(
                        model: model, binding: binding, isEditing: editingID == binding.id,
                        onToggleEdit: {
                            isAddingNew = false
                            editingID = editingID == binding.id ? nil : binding.id
                        })
                }
                if isAddingNew {
                    HotkeyEditor(model: model, existing: nil, onDone: { isAddingNew = false })
                        .padding(.vertical, 10)
                }
            }
            Button("Add hotkey\u{2026}") {
                editingID = nil
                isAddingNew = true
            }
            .buttonStyle(STButtonStyle(.secondary))
            .padding(.top, 8)
            STAdvancedDisclosure(isExpanded: $advancedIsOpen) {
                STSettingsRow("Show a confirmation", showsRule: false) {
                    STSwitch(isOn: confirmationBinding, label: "Show a confirmation")
                }
            }
            .padding(.top, 14)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.hotkeys.isEnabled }, set: { model.hotkeys.isEnabled = $0 })
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { model.hotkeys.showsConfirmation }, set: { model.hotkeys.showsConfirmation = $0 })
    }
}

private struct HotkeyBindingRow: View {
    let model: AppModel
    let binding: HotkeyBinding
    let isEditing: Bool
    let onToggleEdit: () -> Void
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            STSettingsRow(binding.combo.displayString, showsRule: !isEditing) {
                HStack(spacing: 10) {
                    Text(actionsSummary).stStyle(.body).foregroundStyle(STColor.inkSecondary)
                    if let note = statusNote {
                        Text(note).stStyle(.caption).foregroundStyle(STColor.danger)
                    }
                    Button(isEditing ? "Done" : "Edit") { onToggleEdit() }
                        .buttonStyle(STButtonStyle(.quiet))
                }
            }
            if isEditing {
                HotkeyEditor(model: model, existing: binding, onDone: onToggleEdit)
                    .padding(.leading, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    private var actionsSummary: String {
        binding.actions.map(HotkeyActionNaming.title).joined(separator: " + ")
    }

    private var statusNote: String? {
        switch model.hotkeys.status(of: binding.id) {
        case .conflict(.alreadyUsedByYou): "Already used above"
        case .conflict(.systemRefused): "Refused by macOS"
        case .conflict(.invalidCombo(let issue)): HotkeyActionNaming.issueText(issue)
        case .conflict(.noActions): "No actions"
        case .registered, .inactive, nil: nil
        }
    }
}

private struct HotkeyEditor: View {
    let model: AppModel
    let existing: HotkeyBinding?
    let onDone: () -> Void

    @State private var shortcut: STShortcut?
    @State private var actions: Set<HotkeyAction>

    init(model: AppModel, existing: HotkeyBinding?, onDone: @escaping () -> Void) {
        self.model = model
        self.existing = existing
        self.onDone = onDone
        _shortcut = State(initialValue: existing?.combo.asSTShortcut)
        _actions = State(initialValue: Set(existing?.actions ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            STShortcutRecorder(shortcut: $shortcut, label: "Key combination", validate: validate)
                .frame(maxWidth: 260)
            STActionChips(selection: $actions)
            HStack(spacing: 14) {
                Button("Save") { save() }
                    .buttonStyle(STButtonStyle(.primary))
                    .disabled(shortcut == nil || actions.isEmpty)
                if existing != nil {
                    Button("Delete") { delete() }
                        .buttonStyle(STButtonStyle(.secondary))
                }
            }
        }
    }

    private func validate(_ candidate: STShortcut) -> String? {
        let combo = candidate.hotkeyCombo
        guard let conflict = model.hotkeys.conflict(for: combo, excluding: existing?.id) else { return nil }
        switch conflict {
        case .alreadyUsedByYou: return "Already used by another hotkey"
        case .invalidCombo(let issue): return HotkeyActionNaming.issueText(issue)
        case .systemRefused: return "Refused by macOS"
        case .noActions: return nil
        }
    }

    private func save() {
        guard let shortcut else { return }
        let combo = shortcut.hotkeyCombo
        let orderedActions = HotkeyAction.allCases.filter { actions.contains($0) }
        if let existing {
            model.hotkeys.update(existing.id, combo: combo, actions: orderedActions)
        } else {
            model.hotkeys.add(combo: combo, actions: orderedActions)
        }
        onDone()
    }

    private func delete() {
        guard let existing else { return }
        model.hotkeys.remove(existing.id)
        onDone()
    }
}

/// A row of toggleable chips, one per possible hotkey action — any mix can be selected (spec 6.1).
private struct STActionChips: View {
    @Binding var selection: Set<HotkeyAction>
    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(HotkeyAction.allCases, id: \.self) { action in
                let isSelected = selection.contains(action)
                Button {
                    sound.play(.click)
                    if isSelected { selection.remove(action) } else { selection.insert(action) }
                } label: {
                    Text(HotkeyActionNaming.title(action))
                        .stStyle(.label)
                        .foregroundStyle(isSelected ? STColor.background : STColor.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? theme.accent : STColor.surface, in: Capsule())
                        .overlay(Capsule().stroke(theme.stroke, lineWidth: isSelected ? 0 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Wraps chips onto multiple lines instead of overflowing the row.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

enum HotkeyActionNaming {
    static func title(_ action: HotkeyAction) -> String {
        switch action {
        case .toggle(.nbbOverlay): "NBB Overlay"
        case .toggle(.windowBackdrop): "Window Backdrop"
        case .toggle(.crosshair): "Crosshair"
        case .toggle(.screenRecording): "Screen Recording"
        case .startStopRecording: "Start/stop recording"
        }
    }

    static func issueText(_ issue: HotkeyComboIssue) -> String {
        switch issue {
        case .unsupportedKey: "Unsupported key"
        case .reserved(let name): "Reserved: \(name)"
        }
    }
}

extension STShortcut {
    var hotkeyCombo: HotkeyCombo { HotkeyCombo(keyCode: keyCode, modifierRawValue: modifiers.rawValue) }
}

extension HotkeyCombo {
    var asSTShortcut: STShortcut { STShortcut(keyCode: keyCode, modifiers: STShortcutModifiers(rawValue: modifiers.rawValue)) }
}
