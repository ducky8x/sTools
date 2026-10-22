import AppKit
import STDesign
import STPlatform
import SwiftUI

/// Home ▸ Hotkeys (spec 6.1), near the top of Home: the list of hotkeys (key and actions at a glance), Add Hotkey…,
/// an add/edit editor for each, and Advanced (spec 2.4) with the press confirmation. While hotkeys are off, one strip
/// says so with Turn On; while on, the master switch turns them off. Any key works, alone
/// or with modifiers. What the Key Rebinder knows (which key on the keyboard sends a hotkey's key, what Minecraft
/// uses it for) arrives through `model.hotkeys.advisor`; without one, those lines are simply left out.
struct HotkeysSection: View {
    let model: AppModel
    @State private var editingID: UUID?
    @State private var isAddingNew = false
    /// The actions a new hotkey's editor starts with: none for Add Hotkey…, Start timer for Set in Hotkeys….
    @State private var newHotkeyActions: Set<HotkeyAction> = []
    @State private var advancedIsOpen: Bool

    init(model: AppModel, advancedIsOpen: Bool = false, editingID: UUID? = nil) {
        self.model = model
        _advancedIsOpen = State(initialValue: advancedIsOpen)
        _editingID = State(initialValue: editingID)
    }

    private var hotkeys: HotkeyCenter { model.hotkeys }

    /// Opens the add editor with the actions the app asked for, once.
    private func takePendingNewHotkey() {
        guard let actions = model.pendingNewHotkeyActions else { return }
        model.pendingNewHotkeyActions = nil
        editingID = nil
        newHotkeyActions = actions
        isAddingNew = true
    }

    var body: some View {
        PageSectionTitle("Hotkeys").padding(.top, 28).padding(.bottom, 4)
            // Timer Overlay's Set in Hotkeys… asks for a new hotkey with its actions already chosen.
            .onAppear(perform: takePendingNewHotkey)
            .onChange(of: model.pendingNewHotkeyActions) { _, _ in takePendingNewHotkey() }
        // One way to turn hotkeys on while they're off; once on, the switch turns them off again.
        Group {
            if hotkeys.isEnabled {
                STSettingsRow("Hotkeys") {
                    STSwitch(isOn: enabledBinding, label: "Hotkeys")
                }
            } else {
                STRequirementStrip(kind: .warning,
                                   message: Self.offMessage(hasHotkeys: !hotkeys.bindings.isEmpty, scope: hotkeys.scope),
                                   actionTitle: "Turn On", action: { model.hotkeys.isEnabled = true })
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
        // The Key Rebinder's advice reads karabiner.json and Minecraft's keybinds (never karabiner_cli): loaded
        // when hotkeys turn on and each time sTools comes back to the front, so it follows edits made elsewhere.
        .task(id: hotkeys.isEnabled) { await prepareAdvice() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await prepareAdvice() }
        }
        STSettingsRow("Where hotkeys work", showsRule: Self.scopeNote(scope: hotkeys.scope,
                                                                    accessibilityGranted: model.accessibilityGranted) == nil) {
            HotkeysChoiceMenu(title: hotkeys.scope.title,
                              options: HotkeyScope.allCases.map { STSegmentedOption($0, $0.title) },
                              selection: hotkeys.scope, label: "Where hotkeys work") { model.hotkeys.scope = $0 }
        }
        if let note = Self.scopeNote(scope: hotkeys.scope, accessibilityGranted: model.accessibilityGranted) {
            HotkeysCaption(note)
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
                }
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hotkeys.bindings) { binding in
                HotkeyBindingRow(
                    model: model, binding: binding, isEditing: editingID == binding.id,
                    onToggleEdit: {
                        isAddingNew = false
                        editingID = editingID == binding.id ? nil : binding.id
                    })
            }
            if isAddingNew {
                HotkeyEditor(model: model, existing: nil, initialActions: newHotkeyActions, onDone: {
                    isAddingNew = false
                    newHotkeyActions = []
                })
                // An editor already open for Add Hotkey… starts over when Set in Hotkeys… asks for Start timer.
                .id(newHotkeyActions)
                .padding(.vertical, 10)
            }
        }
        if !isAddingNew {
            Button("Add Hotkey\u{2026}") {
                editingID = nil
                newHotkeyActions = []
                isAddingNew = true
            }
            .buttonStyle(STButtonStyle(.secondary))
            .padding(.top, 10)
        }
        if hotkeys.isEnabled {
            STAdvancedDisclosure(isExpanded: $advancedIsOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    STSettingsRow("Show a confirmation", showsRule: false) {
                        STSwitch(isOn: confirmationBinding, label: "Show a confirmation")
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    /// The strip's line while hotkeys are off.
    static func offMessage(hasHotkeys: Bool, scope: HotkeyScope) -> String {
        guard !hasHotkeys else { return "Hotkeys are off, so the keys below do nothing." }
        return switch scope {
        case .sToolsAndMinecraft: "Hotkeys are off. Turn them on to switch tools with a key, in sTools and Minecraft."
        case .everywhere: "Hotkeys are off. Turn them on to switch tools with a key, from any app."
        }
    }

    /// The line under Where hotkeys work: sTools recognizes Minecraft by its windows, which takes Accessibility.
    /// Nil when there is nothing to say.
    static func scopeNote(scope: HotkeyScope, accessibilityGranted: Bool) -> String? {
        guard scope == .sToolsAndMinecraft, !accessibilityGranted else { return nil }
        return "Until Accessibility is allowed, sTools can't tell when Minecraft is in front, so hotkeys work only in sTools."
    }

    private func prepareAdvice() async {
        guard hotkeys.isEnabled else { return }
        await hotkeys.advisor?.prepareAdvice()
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.hotkeys.isEnabled }, set: { model.hotkeys.isEnabled = $0 })
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { model.hotkeys.showsConfirmation }, set: { model.hotkeys.showsConfirmation = $0 })
    }
}

/// One hotkey in the list: the combination, what it does and what's wrong with it, and an Edit button. Below,
/// only when there is something to say: which key on the keyboard sends it (with Show on Keyboard) and what
/// Minecraft loses to it.
struct HotkeyBindingRow: View {
    let model: AppModel
    let binding: HotkeyBinding
    let isEditing: Bool
    let onToggleEdit: () -> Void
    @Environment(\.stTheme) private var theme

    /// What a row says below its first line, from the Key Rebinder's advice.
    struct Details: Equatable {
        /// "On Caps Lock", "No key on your keyboard sends F20"; nil when the key simply sends itself, or without
        /// the Key Rebinder.
        var placement: String?
        /// Whether Show on Keyboard is offered: the caption names a drawn key that sends the hotkey's key.
        var canShow = false
        /// What Minecraft loses to the hotkey.
        var cautions: [HotkeyNote] = []

        var isEmpty: Bool { placement == nil && cautions.isEmpty }
    }

    /// What VoiceOver calls Show on Keyboard: "Show Option F18 on keyboard", so rows don't all read the same.
    static func showOnKeyboardLabel(for combo: HotkeyCombo) -> String {
        "Show \(HotkeyWording.spokenName(for: combo)) on keyboard"
    }

    /// The placement caption, Show on Keyboard and the cautions for `binding`. While the row is being edited, its
    /// editor shows every note for the combination being recorded, so the row leaves the cautions out.
    static func details(for binding: HotkeyBinding, isEditing: Bool, hotkeys: HotkeyCenter) -> Details {
        let placement = hotkeys.advisor?.placement(of: binding.combo)
        let cautions = isEditing ? [] : hotkeys.notes(for: binding.combo).filter { $0.tone == .caution }
        return Details(placement: placement?.text, canShow: placement?.text != nil && placement?.canShow == true, cautions: cautions)
    }

    var body: some View {
        let details = Self.details(for: binding, isEditing: isEditing, hotkeys: model.hotkeys)
        VStack(alignment: .leading, spacing: 0) {
            summaryLine
                .padding(.top, 12)
                .padding(.bottom, details.isEmpty ? 12 : 6)
            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let text = details.placement {
                        HStack(spacing: 12) {
                            HotkeysCaption(text)
                            if details.canShow {
                                Button("Show on Keyboard") { model.showHotkeyOnKeyboard(binding.combo) }
                                    .buttonStyle(STButtonStyle(.quiet))
                                    .accessibilityLabel(Self.showOnKeyboardLabel(for: binding.combo))
                            }
                        }
                    }
                    ForEach(Array(details.cautions.enumerated()), id: \.offset) { _, caution in
                        STNoteLine(caution)
                    }
                }
                .padding(.bottom, 12)
            }
            if isEditing {
                HotkeyEditor(model: model, existing: binding, onDone: onToggleEdit)
                    .padding(.leading, 12)
                    .padding(.bottom, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if !isEditing {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
        }
    }

    /// The row's first line. VoiceOver reads it as one element ("Option F18: Crosshair and NBB Overlay. Refused
    /// by macOS."), with Edit as its own button.
    private var summaryLine: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(binding.combo.displayString)
                    .stStyle(.label)
                    .foregroundStyle(STColor.ink)
                Spacer(minLength: 16)
                Text(HotkeyWording.summary(binding.actions))
                    .stStyle(.body)
                    .foregroundStyle(theme.inkSecondary)
                if let note = statusNote {
                    Text(note)
                        .stStyle(.caption)
                        .foregroundStyle(STColor.danger)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenDescription)
            Button(isEditing ? "Done" : "Edit") { onToggleEdit() }
                .buttonStyle(STButtonStyle(.quiet))
                .accessibilityLabel(isEditing ? "Done editing \(spokenName)" : "Edit \(spokenName)")
        }
    }

    private var statusNote: String? {
        HotkeyWording.statusNote(model.hotkeys.status(of: binding.id), combo: binding.combo)
    }

    private var spokenName: String { HotkeyWording.spokenName(for: binding.combo) }

    private var spokenDescription: String {
        let summary = HotkeyWording.spokenSummary(binding.actions)
        let sentences = [summary.isEmpty ? spokenName : "\(spokenName): \(summary)", statusNote].compactMap { $0 }
        return sentences.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }
}

/// Adds or edits one hotkey: record any key or combination, read what it would take away, pick its actions.
struct HotkeyEditor: View {
    let model: AppModel
    let existing: HotkeyBinding?
    let onDone: () -> Void

    @State private var shortcut: STShortcut?
    @State private var actions: Set<HotkeyAction>
    private let initialActions: Set<HotkeyAction>

    /// `initialActions` chooses a new hotkey's actions up front (Timer Overlay's Set in Hotkeys…).
    init(model: AppModel, existing: HotkeyBinding?, initialActions: Set<HotkeyAction> = [], onDone: @escaping () -> Void) {
        self.model = model
        self.existing = existing
        self.onDone = onDone
        self.initialActions = initialActions
        _shortcut = State(initialValue: existing?.combo.asSTShortcut)
        _actions = State(initialValue: existing.map { Set($0.actions) } ?? initialActions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A new hotkey opened with its actions chosen (Set in Hotkeys…) is ready for its key at once.
            STShortcutRecorder(shortcut: $shortcut, label: "Key or combination",
                               startsRecording: existing == nil && !initialActions.isEmpty, validate: validate)
                .frame(maxWidth: 260)
            if let combo = shortcut?.hotkeyCombo {
                let notes = model.hotkeys.notes(for: combo)
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            STNoteLine(note)
                        }
                    }
                }
            }
            STChips(selection: $actions, options: HotkeyAction.allCases.map { STSegmentedOption($0, $0.title) }, label: "Actions")
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

    /// While recording, only real problems refuse a key: a duplicate, a combination macOS keeps, or a key sTools
    /// doesn't know. Everything else is a note.
    private func validate(_ candidate: STShortcut) -> String? {
        let combo = candidate.hotkeyCombo
        guard let conflict = model.hotkeys.conflict(for: combo, excluding: existing?.id), conflict != .noActions else { return nil }
        return HotkeyWording.conflictText(conflict, combo: combo, inList: false)
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

/// A pop-up menu that picks one of `options`, in the app's type (`STMenuLabel`), with a check beside the current one.
/// `selection` may be nil when no option fits (a key set nobody picked), and `title` then says what the state is.
struct HotkeysChoiceMenu<Value: Hashable>: View {
    let title: String
    let options: [STSegmentedOption<Value>]
    let selection: Value?
    let label: String
    let choose: (Value) -> Void

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button { choose(option.value) } label: {
                    if option.value == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            STMenuLabel(title)
        }
        .stMenuStyle()
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}

/// A tertiary caption that wraps instead of truncating.
private struct HotkeysCaption: View {
    private let text: String
    @Environment(\.stTheme) private var theme

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .stStyle(.caption)
            .foregroundStyle(theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension STNoteLine {
    /// A hotkey note in the house style: a caution leads with the danger dot.
    init(_ note: HotkeyNote) {
        switch note.tone {
        case .note: self.init(note.text, tone: .note)
        case .caution: self.init(note.text, tone: .caution)
        }
    }
}

extension STShortcut {
    var hotkeyCombo: HotkeyCombo { HotkeyCombo(keyCode: keyCode, modifierRawValue: modifiers.rawValue) }
}

extension HotkeyCombo {
    var asSTShortcut: STShortcut { STShortcut(keyCode: keyCode, modifiers: STShortcutModifiers(rawValue: modifiers.rawValue)) }
}
