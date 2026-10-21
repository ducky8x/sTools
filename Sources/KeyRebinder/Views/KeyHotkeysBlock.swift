import STDesign
import STPlatform
import SwiftUI

/// The key panel's Hotkeys part (spec 5.5.3, 6.1): the sTools hotkeys on what the selected key sends after
/// Karabiner, an inline editor that adds or changes one with Hold and Does chips, and, for a key that can't carry
/// hotkeys, why not and the spare key it could become. Hotkeys live in `hotkeys.json`, never in `karabiner.json`, so
/// all of this works without Karabiner-Elements; only Use F20 needs it. The panel gives the block `.id(key)`, so
/// selecting another key closes the editor unsaved.
struct KeyHotkeysBlock: View {
    /// What the block shows for a key.
    enum Content: Equatable {
        /// Home ▸ Hotkeys' master switch is off.
        case off
        /// The key sends the virtual key `keyCode`, which hotkeys can listen for.
        case carries(keyCode: UInt16)
        /// The key can't carry hotkeys: why not, the spare key Use F20 would put in Becomes (nil when it isn't
        /// offered), and whether a rule drives the key, so Home has to record its hotkey by pressing it.
        case unavailable(reason: String, spare: KarabinerEvent?, isRuleDriven: Bool)
    }

    @Bindable var controller: KeyRebinderController
    let key: KarabinerEvent
    /// The panel's Becomes. Use F20 only puts the spare key there; nothing is written until the panel's Save.
    @Binding var chosen: KarabinerEvent?
    /// Opens Home ▸ Hotkeys, for a key a rule drives. Nil leaves Open Hotkeys out.
    let openHotkeys: (() -> Void)?

    /// The inline editor's choices; nil while it's closed.
    @State private var draft: HotkeyDraft?
    @Environment(\.stTheme) private var theme

    /// - Parameter draft: opens the editor with these choices (for tests and previews).
    init(
        controller: KeyRebinderController, key: KarabinerEvent, chosen: Binding<KarabinerEvent?>,
        openHotkeys: (() -> Void)?, draft: HotkeyDraft? = nil
    ) {
        self.controller = controller
        self.key = key
        _chosen = chosen
        self.openHotkeys = openHotkeys
        _draft = State(initialValue: draft)
    }

    /// What the block shows for `key`: Turn On while hotkeys are off, else its hotkeys when it can carry them, else
    /// why it can't.
    static func content(for key: KarabinerEvent, controller: KeyRebinderController) -> Content {
        guard controller.hotkeysAreOn else { return .off }
        let target = controller.hotkeyTarget(for: key)
        if let keyCode = target.keyCode { return .carries(keyCode: keyCode) }
        return .unavailable(
            reason: controller.hotkeyUnavailableText(for: key) ?? "", spare: controller.spareKeyOffer(for: key),
            isRuleDriven: target == .ruleDriven)
    }

    var body: some View {
        switch Self.content(for: key, controller: controller) {
        case .off:
            offLine
        case .carries(let keyCode):
            hotkeys(on: keyCode)
        case .unavailable(let reason, let spare, let isRuleDriven):
            unavailable(reason, spare: spare, isRuleDriven: isRuleDriven)
        }
    }

    // MARK: Off

    private var offLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("sTools hotkeys are off.").stStyle(.body).foregroundStyle(theme.inkSecondary)
            Button("Turn On") { controller.turnHotkeysOn() }
                .buttonStyle(STButtonStyle(.quiet))
                .accessibilityLabel("Turn on sTools hotkeys")
        }
    }

    // MARK: A key that carries hotkeys

    /// The key's hotkeys, one row each, with the editor in place of the row being edited or of Add Hotkey….
    /// Editing waits while a karabiner.json change waits for Save This or Discard.
    @ViewBuilder private func hotkeys(on keyCode: UInt16) -> some View {
        let hotkeys = controller.hotkeys(on: key)
        let isWaiting = controller.pendingEdit != nil
        VStack(alignment: .leading, spacing: 0) {
            if let note = controller.hotkeySourceNote(for: key) {
                Text(note)
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            ForEach(hotkeys) { hotkey in
                if draft?.editing == hotkey.id {
                    editor(on: keyCode, existing: hotkey).padding(.vertical, 10)
                } else {
                    row(hotkey).disabled(isWaiting)
                }
            }
            if let draft, !hotkeys.contains(where: { $0.id == draft.editing }) {
                editor(on: keyCode, existing: nil).padding(.top, 10)
            } else {
                Button("Add Hotkey\u{2026}") { draft = HotkeyDraft() }
                    .buttonStyle(STButtonStyle(.secondary))
                    .disabled(isWaiting)
                    .padding(.top, 10)
            }
        }
    }

    /// One hotkey: its combination, what it does and what's wrong with it, then Edit. VoiceOver reads the first
    /// three as one sentence ("Option F18: Crosshair and NBB Overlay. Refused by macOS.").
    private func row(_ hotkey: HotkeyBinding) -> some View {
        let problem = HotkeyWording.statusNote(controller.hotkeyCenter?.status(of: hotkey.id), combo: hotkey.combo, inList: false)
        let name = HotkeyWording.spokenName(for: hotkey.combo)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(hotkey.combo.displayString).stStyle(.label).foregroundStyle(STColor.ink)
                Text(HotkeyWording.summary(hotkey.actions)).stStyle(.body).foregroundStyle(theme.inkSecondary)
                if let problem {
                    Text(problem)
                        .stStyle(.caption)
                        .foregroundStyle(STColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenDescription(name: name, actions: hotkey.actions, problem: problem))
            Spacer(minLength: 8)
            Button("Edit") { draft = HotkeyDraft(hotkey) }
                .buttonStyle(STButtonStyle(.quiet))
                .accessibilityLabel("Edit \(name)")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true) }
    }

    /// "Option F18: Crosshair and NBB Overlay. Refused by macOS."
    static func spokenDescription(name: String, actions: [HotkeyAction], problem: String?) -> String {
        let summary = HotkeyWording.spokenSummary(actions)
        let sentences = [summary.isEmpty ? name : "\(name): \(summary)", problem].compactMap { $0 }
        return sentences.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    // MARK: The editor

    /// Adds a hotkey on `keyCode`, or changes `existing`: the combination, Hold and Does chips, what blocks saving,
    /// the notes (which never block), then Save Hotkey (secondary: the rebind's Save stays the panel's one primary
    /// button), Delete and Cancel.
    private func editor(on keyCode: UInt16, existing: HotkeyBinding?) -> some View {
        let draft = draft ?? HotkeyDraft()
        let combo = draft.combo(on: keyCode)
        let center = controller.hotkeyCenter
        let problem = center.flatMap { draft.problem(on: keyCode, in: $0) }
        let notes = center?.notes(for: combo) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text(combo.displayString)
                .stStyle(.body)
                .foregroundStyle(theme.accent)
                .accessibilityLabel(HotkeyWording.spokenName(for: combo))
            chipsRow("Hold") {
                STChips(selection: holdSelection, options: HotkeyDraft.holdChoices, label: "Hold")
            }
            chipsRow("Does") {
                STChips(selection: doesSelection, options: HotkeyAction.allCases.map { STSegmentedOption($0, $0.title) }, label: "Does")
            }
            if let problem {
                Text(problem).stStyle(.caption).foregroundStyle(STColor.danger)
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        STNoteLine(note.text, tone: note.tone == .caution ? .caution : .note)
                    }
                }
            }
            HStack(spacing: 14) {
                Button("Save Hotkey") { save() }
                    .buttonStyle(STButtonStyle(.secondary))
                    .disabled(center.map { !draft.canSave(on: keyCode, in: $0) } ?? true)
                if let existing {
                    Button("Delete") {
                        controller.deleteHotkey(existing.id)
                        self.draft = nil
                    }
                    .buttonStyle(STButtonStyle(.quiet))
                    .accessibilityLabel("Delete \(HotkeyWording.spokenName(for: existing.combo))")
                }
                Button("Cancel") { self.draft = nil }.buttonStyle(STButtonStyle(.quiet))
            }
        }
        .disabled(controller.pendingEdit != nil)
    }

    /// A small-caps label beside its chips. The chips name their own group for VoiceOver.
    private func chipsRow<Chips: View>(_ label: String, @ViewBuilder chips: () -> Chips) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .stStyle(.label)
                .foregroundStyle(theme.inkSecondary)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 6)
                .accessibilityHidden(true)
            chips()
        }
    }

    private var holdSelection: Binding<Set<HotkeyCombo.Modifiers>> {
        Binding(get: { draft?.hold ?? [] }, set: { draft?.hold = $0 })
    }

    private var doesSelection: Binding<Set<HotkeyAction>> {
        Binding(get: { draft?.does ?? [] }, set: { draft?.does = $0 })
    }

    private func save() {
        guard let draft else { return }
        let actions = HotkeyAction.allCases.filter(draft.does.contains)
        if controller.saveHotkey(on: key, editing: draft.editing, modifiers: draft.modifiers, actions: actions) != nil {
            self.draft = nil
        }
    }

    // MARK: A key that can't carry hotkeys

    private func unavailable(_ reason: String, spare: KarabinerEvent?, isRuleDriven: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason)
                .stStyle(.body)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let opensHotkeys = isRuleDriven ? openHotkeys : nil
            if spare != nil || opensHotkeys != nil {
                HStack(spacing: 14) {
                    if let spare {
                        let name = KeyNames.name(for: spare)
                        Button("Use \(name)") { chosen = spare }
                            .buttonStyle(STButtonStyle(.quiet))
                            .disabled(chosen == spare)
                            .help("Puts \(name) in Becomes. Save writes the rebind.")
                    }
                    if let opensHotkeys {
                        Button("Open Hotkeys", action: opensHotkeys).buttonStyle(STButtonStyle(.quiet))
                    }
                }
            }
        }
    }
}

/// What the Hotkeys part's editor holds until Save Hotkey: the hotkey it changes (nil adds one), the modifiers to
/// hold and the actions.
struct HotkeyDraft: Equatable {
    /// The four modifiers, one chip each, in macOS's order (⌃⌥⇧⌘). None chosen means the key alone.
    static var holdChoices: [STSegmentedOption<HotkeyCombo.Modifiers>] {
        [
            STSegmentedOption(.control, "Control"), STSegmentedOption(.option, "Option"),
            STSegmentedOption(.shift, "Shift"), STSegmentedOption(.command, "Command"),
        ]
    }

    /// The hotkey being changed; nil adds a new one.
    var editing: UUID?
    var hold: Set<HotkeyCombo.Modifiers> = []
    var does: Set<HotkeyAction> = []

    /// A new hotkey: the key alone, and no action yet.
    init() {}

    /// Changing `binding`: its modifiers and actions.
    init(_ binding: HotkeyBinding) {
        editing = binding.id
        hold = Set(Self.holdChoices.map(\.value).filter(binding.combo.modifiers.contains))
        does = Set(binding.actions)
    }

    /// The modifiers chosen, together.
    var modifiers: HotkeyCombo.Modifiers {
        hold.reduce(into: []) { $0.formUnion($1) }
    }

    func combo(on keyCode: UInt16) -> HotkeyCombo {
        HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    /// What blocks saving, in words: macOS keeps the combination, or another hotkey already uses it. Nil when
    /// nothing does. Notes never block.
    @MainActor
    func problem(on keyCode: UInt16, in center: HotkeyCenter) -> String? {
        let combo = combo(on: keyCode)
        return center.conflict(for: combo, excluding: editing).map { HotkeyWording.conflictText($0, combo: combo, inList: false) }
    }

    /// Save Hotkey needs an action and no problem.
    @MainActor
    func canSave(on keyCode: UInt16, in center: HotkeyCenter) -> Bool {
        !does.isEmpty && problem(on: keyCode, in: center) == nil
    }
}
