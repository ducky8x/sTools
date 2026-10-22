import AppKit
import STDesign
import STPlatform
import SwiftUI

/// Home ▸ Hotkeys (spec 6.1), near the top of Home: Where hotkeys work and the key sets, each with every option in view
/// and the sets with what the current one gives each tool, the list of hotkeys (key and actions at a glance), Add
/// Hotkey…, an add/edit editor for each, and Advanced (spec 2.4) with the press confirmation. While hotkeys are off,
/// one strip says so with Turn On; while on, the master switch turns them off. Any key works, alone or with modifiers.
/// What the Key Rebinder knows (which key on the keyboard sends a hotkey's key, what Minecraft uses it for) arrives
/// through `model.hotkeys.advisor`; without one, those lines are simply left out.
struct HotkeysSection: View {
    let model: AppModel
    @State private var editingID: UUID?
    @State private var isAddingNew = false
    /// The actions a new hotkey's editor starts with: none for Add Hotkey…, Start timer for Set in Hotkeys….
    @State private var newHotkeyActions: Set<HotkeyAction> = []
    @State private var advancedIsOpen: Bool
    /// The key set waiting for the answer to "Replace the keys you set?".
    @State private var pendingKeySet: HotkeyKeySet?
    /// The hotkey whose editor opened recording (Set in Hotkeys… for the timer's own key).
    @State private var recordingID: UUID?

    init(model: AppModel, advancedIsOpen: Bool = false, editingID: UUID? = nil) {
        self.model = model
        _advancedIsOpen = State(initialValue: advancedIsOpen)
        _editingID = State(initialValue: editingID)
    }

    private var hotkeys: HotkeyCenter { model.hotkeys }

    /// What another page asks Home ▸ Hotkeys to open (Timer Overlay's Set in Hotkeys…).
    enum EditorRequest: Equatable {
        /// The editor of this hotkey, recording a new key: the timer's own Start-timer key.
        case edit(UUID)
        /// A new hotkey with these actions chosen, ready for its key.
        case add(Set<HotkeyAction>)
    }

    /// Takes the request waiting in `model`, once: it's cleared, so the next call returns nil.
    static func takeEditorRequest(from model: AppModel) -> EditorRequest? {
        if let id = model.pendingEditHotkeyID {
            model.pendingEditHotkeyID = nil
            return .edit(id)
        }
        if let actions = model.pendingNewHotkeyActions {
            model.pendingNewHotkeyActions = nil
            return .add(actions)
        }
        return nil
    }

    /// Opens the editor the app asked for, once.
    private func takeEditorRequest() {
        switch Self.takeEditorRequest(from: model) {
        case .edit(let id)?:
            isAddingNew = false
            newHotkeyActions = []
            editingID = id
            recordingID = id
        case .add(let actions)?:
            editingID = nil
            newHotkeyActions = actions
            isAddingNew = true
        case nil:
            break
        }
    }

    var body: some View {
        PageSectionTitle("Hotkeys").padding(.top, 28).padding(.bottom, 4)
            // Timer Overlay's Set in Hotkeys… asks for its own key's editor, or a new hotkey with Start timer chosen.
            .onAppear(perform: takeEditorRequest)
            .onChange(of: model.pendingNewHotkeyActions) { _, _ in takeEditorRequest() }
            .onChange(of: model.pendingEditHotkeyID) { _, _ in takeEditorRequest() }
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
        // Both choices stay in view, every option at once, rather than behind menus (revision 9).
        let scopeNote = Self.scopeNote(scope: hotkeys.scope, accessibilityGranted: model.accessibilityGranted)
        HotkeysChoiceRow("Where hotkeys work", showsRule: scopeNote == nil) {
            STSegmented(selection: scopeBinding, options: Self.scopeOptions)
        }
        if let scopeNote {
            HotkeysCaption(scopeNote).hotkeysCaptionRow()
        }
        // One key per tool, in sidebar order; picking a set changes only those, and asks before a key set by hand goes.
        // Nothing is underlined while the keys are Custom.
        HotkeysChoiceRow("Key set", showsRule: false) {
            STSegmented(selection: keySetBinding, options: Self.keySetOptions)
        }
        HotkeysCaption(Self.keySetCaption(hotkeys.keySet)).hotkeysCaptionRow()
        .confirmationDialog(
            pendingKeySet.map { Self.keySetQuestion($0) } ?? "", isPresented: keySetQuestionIsShown,
            titleVisibility: .visible, presenting: pendingKeySet,
            actions: { set in
                Button(set == .noKeys ? "Remove" : "Replace", role: .destructive) { model.hotkeys.apply(set) }
                Button("Cancel", role: .cancel) {}
            },
            message: { set in Text(Self.keySetWarning(set, bindings: hotkeys.bindings)) })
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hotkeys.bindings) { binding in
                HotkeyBindingRow(
                    model: model, binding: binding, isEditing: editingID == binding.id,
                    recordsAtOnce: recordingID == binding.id,
                    onToggleEdit: {
                        isAddingNew = false
                        recordingID = nil
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

    /// Where hotkeys work, both choices in view.
    static var scopeOptions: [STSegmentedOption<HotkeyScope>] {
        HotkeyScope.allCases.map { STSegmentedOption($0, $0.title) }
    }

    /// Every key set in view, in the order the arrow keys cycle through them. While the keys are Custom (`keySet` is
    /// nil) none of them is underlined.
    static var keySetOptions: [STSegmentedOption<HotkeyKeySet?>] {
        HotkeyKeySet.allCases.map { STSegmentedOption(Optional($0), $0.title) }
    }

    /// The set's name: the set the tools' own hotkeys follow, or Custom once a key was set by hand.
    static func keySetTitle(_ set: HotkeyKeySet?) -> String { HotkeyKeySet.name(of: set) }

    /// The line under the key sets: what the current set gives each tool, in sidebar order ("⌘1 Crosshair · ⌘2
    /// Timer Overlay · …", each key and tool held together by no-break spaces so a narrow column wraps between
    /// them), that None gives none a key, or, while the keys are Custom, whose keys they are.
    static func keySetCaption(_ set: HotkeyKeySet?) -> String {
        guard let set else { return "Custom: keys you set yourself. Pick a set for one key per tool, in sidebar order." }
        let keys = HotkeyKeySet.toolActions.compactMap { action in
            set.combo(for: action).map { combo in
                "\(combo.displayString) \(toolName(for: action))".replacingOccurrences(of: " ", with: "\u{00A0}")
            }
        }
        return keys.isEmpty ? "No tool has a key of its own." : keys.joined(separator: " · ")
    }

    /// The confirmation's title before `set` replaces keys set by hand: "Use ⌃1–⌃5?", "Remove every tool's key?".
    static func keySetQuestion(_ set: HotkeyKeySet) -> String {
        set == .noKeys ? "Remove every tool's key?" : "Use \(set.title)?"
    }

    /// What picking `set` would take away: "This replaces the key you set for Crosshair (F6)." Other hotkeys stay.
    static func keySetWarning(_ set: HotkeyKeySet, bindings: [HotkeyBinding]) -> String {
        let edits = set.replacedEdits(in: bindings).map { binding in
            "\(toolName(for: binding.actions.first)) (\(binding.combo.displayString))"
        }
        let list = edits.count > 1 ? edits.dropLast().joined(separator: ", ") + " and " + (edits.last ?? "") : (edits.first ?? "")
        let verb = set == .noKeys ? "removes" : "replaces"
        let keys = edits.count > 1 ? "keys" : "key"
        return "This \(verb) the \(keys) you set for \(list). Your other hotkeys stay as they are."
    }

    /// The tool a key set's action belongs to (`ToolID.hotkeyAction`): Start timer is Timer Overlay's, and Screen
    /// Recording's one action is Screen Recording's.
    private static func toolName(for action: HotkeyAction?) -> String {
        guard let action else { return "" }
        return ToolID.allCases.first { $0.hotkeyAction == action }?.title ?? action.title
    }

    /// Picks `set` at once, or asks first when it would replace a key set by hand.
    private func chooseKeySet(_ set: HotkeyKeySet) {
        if set.replacedEdits(in: hotkeys.bindings).isEmpty {
            model.hotkeys.apply(set)
        } else {
            pendingKeySet = set
        }
    }

    private var keySetQuestionIsShown: Binding<Bool> {
        Binding(get: { pendingKeySet != nil }, set: { if !$0 { pendingKeySet = nil } })
    }

    /// The key set the tools' own hotkeys follow, nil while Custom. Picking one goes through `chooseKeySet`, so it may
    /// ask first and leave the keys as they are.
    private var keySetBinding: Binding<HotkeyKeySet?> {
        Binding(get: { model.hotkeys.keySet }, set: { set in if let set { chooseKeySet(set) } })
    }

    private var scopeBinding: Binding<HotkeyScope> {
        Binding(get: { model.hotkeys.scope }, set: { model.hotkeys.scope = $0 })
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
    /// Whether its editor opens recording a new key (Set in Hotkeys… for the timer's own key).
    var recordsAtOnce = false
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
                HotkeyEditor(model: model, existing: binding, startsRecording: recordsAtOnce, onDone: onToggleEdit)
                    // An editor already open starts over, recording, when Set in Hotkeys… asks for it.
                    .id(recordsAtOnce)
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

/// Adds or edits one hotkey: record any key or combination, read what it would take away, pick its actions. A tool
/// has one key of its own (spec 6.1), so a save that would add a second key for a tool's action alone asks first, and
/// Replace gives the tool's own key the new one instead.
struct HotkeyEditor: View {
    let model: AppModel
    let existing: HotkeyBinding?
    let onDone: () -> Void

    @State private var shortcut: STShortcut?
    @State private var actions: Set<HotkeyAction>
    /// The tool's own hotkey a save would duplicate, with the key it would get instead: the question's subject.
    @State private var replacing: Replacement?
    private let initialActions: Set<HotkeyAction>
    private let startsRecording: Bool

    /// What Save did.
    enum SaveResult: Equatable {
        /// The hotkey was saved, in its sidebar place when it's a tool's own.
        case saved
        /// Nothing was saved: it would be a second key for this tool's own hotkey's action, so the editor asks first.
        case asksToReplace(HotkeyBinding)
    }

    /// A tool's own hotkey and the key Replace would give it.
    struct Replacement: Equatable {
        let own: HotkeyBinding
        let combo: HotkeyCombo
    }

    /// `initialActions` chooses a new hotkey's actions up front (Timer Overlay's Set in Hotkeys…). `startsRecording`
    /// opens an existing hotkey recording a new key (Set in Hotkeys… for the timer's own key).
    init(model: AppModel, existing: HotkeyBinding?, initialActions: Set<HotkeyAction> = [], startsRecording: Bool = false,
         onDone: @escaping () -> Void) {
        self.model = model
        self.existing = existing
        self.onDone = onDone
        self.initialActions = initialActions
        self.startsRecording = startsRecording
        _shortcut = State(initialValue: existing?.combo.asSTShortcut)
        _actions = State(initialValue: existing.map { Set($0.actions) } ?? initialActions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A new hotkey opened with its actions chosen (Set in Hotkeys…) is ready for its key at once, and so is the
            // timer's own key opened by Set in Hotkeys….
            STShortcutRecorder(shortcut: $shortcut, label: "Key or combination",
                               startsRecording: startsRecording || (existing == nil && !initialActions.isEmpty),
                               validate: validate)
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
        .confirmationDialog(
            replacing.map { HotkeyWording.replaceOwnKeyQuestion($0.own, with: $0.combo) } ?? "",
            isPresented: replaceQuestionIsShown, titleVisibility: .visible, presenting: replacing,
            actions: { replacement in
                Button("Replace", role: .destructive) { replace(replacement) }
                Button("Cancel", role: .cancel) {}
            },
            message: { replacement in Text(HotkeyWording.replaceOwnKeyWarning(replacement.own, with: replacement.combo)) })
    }

    /// Saves `combo` and `actions` (kept in the chips' order) on `existing`, or as a new hotkey, unless that would add
    /// a second key for one tool's action alone: then nothing changes, and the tool's own hotkey comes back for the
    /// question (`HotkeyCenter.ownHotkeyReplaced(bySaving:editing:)`).
    static func save(_ combo: HotkeyCombo, actions: Set<HotkeyAction>, existing: HotkeyBinding?, in hotkeys: HotkeyCenter) -> SaveResult {
        let ordered = HotkeyAction.allCases.filter(actions.contains)
        if let own = hotkeys.ownHotkeyReplaced(bySaving: ordered, editing: existing?.id) { return .asksToReplace(own) }
        if let existing {
            hotkeys.update(existing.id, combo: combo, actions: ordered)
        } else {
            hotkeys.add(combo: combo, actions: ordered)
        }
        return .saved
    }

    /// Replace: `own`, a tool's own hotkey, gets `combo`, and `existing`, the hotkey that was being edited into that
    /// tool's action, goes.
    static func replace(_ own: HotkeyBinding, with combo: HotkeyCombo, editing existing: HotkeyBinding?, in hotkeys: HotkeyCenter) {
        guard let action = own.actions.first else { return }
        hotkeys.replaceOwnHotkey(for: action, with: combo, removing: existing?.id)
    }

    private var replaceQuestionIsShown: Binding<Bool> {
        Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })
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
        switch Self.save(combo, actions: actions, existing: existing, in: model.hotkeys) {
        case .saved: onDone()
        case .asksToReplace(let own): replacing = Replacement(own: own, combo: combo)
        }
    }

    private func replace(_ replacement: Replacement) {
        Self.replace(replacement.own, with: replacement.combo, editing: existing, in: model.hotkeys)
        onDone()
    }

    private func delete() {
        guard let existing else { return }
        model.hotkeys.remove(existing.id)
        onDone()
    }
}

/// A choice Home ▸ Hotkeys keeps in view (Where hotkeys work, Key set): its small-caps label with every option beside
/// it, as a settings row, or the options under the label when the column is too narrow for both on one line.
private struct HotkeysChoiceRow<Control: View>: View {
    private let label: String
    private let showsRule: Bool
    private let control: Control
    @Environment(\.stTheme) private var theme

    init(_ label: String, showsRule: Bool = true, @ViewBuilder control: () -> Control) {
        self.label = label
        self.showsRule = showsRule
        self.control = control()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            STSettingsRow(label, showsRule: showsRule) { control.fixedSize() }
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .stStyle(.label)
                    .foregroundStyle(theme.inkSecondary)
                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                if showsRule {
                    Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private extension View {
    /// A caption that finishes a row of Home ▸ Hotkeys: the row's rule under it.
    func hotkeysCaptionRow() -> some View {
        padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
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
