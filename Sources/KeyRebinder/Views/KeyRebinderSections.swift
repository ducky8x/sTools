import STDesign
import SwiftUI

/// A section heading inside the page, marked as a header for VoiceOver.
struct SectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).stStyle(.sectionTitle).foregroundStyle(STColor.ink).accessibilityAddTraits(.isHeader)
    }
}

/// What F1–F12 do without fn held (spec 5.5.2).
struct FnKeysSection: View {
    @Bindable var controller: KeyRebinderController
    @State private var picking: Int?
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("fn function keys")
            Text("What F1\u{2013}F12 do on a Mac keyboard when fn isn\u{2019}t held.")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(1...12, id: \.self) { number in chip(number) }
            }
        }
    }

    private func chip(_ number: Int) -> some View {
        let fnKeys = controller.derived.fnKeys
        let action = fnKeys.indices.contains(number - 1) ? KeyNames.name(for: fnKeys[number - 1]) : ""
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { picking = number } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("F\(number)").stStyle(.label).foregroundStyle(STColor.ink)
                Text(action).stStyle(.caption).foregroundStyle(theme.inkSecondary).lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(STColor.raised, in: shape)
            .overlay { shape.strokeBorder(STColor.rule, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!controller.canEdit || controller.isBusy)
        .accessibilityLabel("F\(number): \(action)")
        .popover(isPresented: Binding(get: { picking == number }, set: { if !$0 { picking = nil } })) {
            VStack(alignment: .leading, spacing: 0) {
                Button("Use Karabiner\u{2019}s Default") {
                    picking = nil
                    Task { await controller.setFnKey(number, to: nil) }
                }
                .buttonStyle(STButtonStyle(.quiet))
                .padding([.top, .horizontal], 14)
                KeyPicker { picked in
                    picking = nil
                    Task { await controller.setFnKey(number, to: picked) }
                }
            }
            .background(STColor.surface)
        }
    }
}

/// The conflict & rule checker's findings (spec 5.5.4), then, when the page shows hotkeys, the hotkey findings.
/// Advisory only.
struct FindingsSection: View {
    let controller: KeyRebinderController
    /// Whether the hotkey findings are listed. False in the Prologue's trial.
    var showsHotkeyFindings = true
    @Environment(\.stTheme) private var theme

    var body: some View {
        let findings = Self.findings(controller: controller, showsHotkeyFindings: showsHotkeyFindings)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading("Checker")
                Spacer()
                Button("Turn Off") { controller.settings.checkerEnabled = false }
                    .buttonStyle(STButtonStyle(.quiet))
                    .help("Hide the checker and its red dots. Turn it back on in the settings below.")
            }
            Text(Self.caption(
                keybindsKnown: controller.minecraftKeybinds != nil,
                hotkeyFindingsCanShow: Self.hotkeyFindingsCanShow(controller: controller, showsHotkeyFindings: showsHotkeyFindings)))
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if findings.isEmpty {
                Text("No problems found.").stStyle(.body).foregroundStyle(theme.inkSecondary)
            }
            ForEach(findings) { finding in
                FindingRow(finding: finding) { select(finding) }
            }
        }
    }

    /// The rule findings, then the hotkey findings when they're listed.
    static func findings(controller: KeyRebinderController, showsHotkeyFindings: Bool) -> [CheckerFinding] {
        controller.derived.findings + (showsHotkeyFindings ? controller.derived.hotkeyFindings : [])
    }

    /// Whether hotkey findings can show at all: they're listed, Show hotkeys is on and hotkeys are on.
    static func hotkeyFindingsCanShow(controller: KeyRebinderController, showsHotkeyFindings: Bool) -> Bool {
        showsHotkeyFindings && controller.showsHotkeyLayer && controller.hotkeysAreOn
    }

    /// Without Minecraft's keybinds, speedrun-rule findings count every key as a game input, and hotkey findings
    /// (when they can show) check against Minecraft 1.16.1's default keys.
    static func caption(keybindsKnown: Bool, hotkeyFindingsCanShow: Bool) -> String {
        guard !keybindsKnown else {
            return "Advisory only: nothing is ever blocked. Speedrun-rule findings cover keys Minecraft uses."
        }
        return "Advisory only: nothing is ever blocked. Without Minecraft\u{2019}s keybinds, speedrun-rule findings count every key as a game input"
            + (hotkeyFindingsCanShow ? ", and hotkey findings use Minecraft\u{2019}s default keys." : ".")
    }

    private func select(_ finding: CheckerFinding) {
        let drawn = Set(controller.physicalKeys.map(KeyTable.shared.canonical))
        guard let key = finding.keys.first(where: { drawn.contains(KeyTable.shared.canonical($0)) }) else { return }
        controller.selectedKey = controller.physicalKeys.first { KeyTable.shared.canonical($0) == KeyTable.shared.canonical(key) }
    }
}

private struct FindingRow: View {
    let finding: CheckerFinding
    let onSelect: () -> Void

    @State private var showsRule = false
    @Environment(\.stTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.kind.title).stStyle(.label)
                        .foregroundStyle(finding.kind.rule == nil ? theme.inkSecondary : theme.accent)
                    Text(finding.message).stStyle(.body).foregroundStyle(STColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the key on the keyboard")
            if let rule = finding.kind.rule {
                DisclosureGroup(isExpanded: $showsRule) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rule.quote, id: \.self) { line in
                            Text(line).stStyle(.caption).italic().foregroundStyle(theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Link("Read the speedrun rules (\(SpeedrunRule.rulesVersion))", destination: SpeedrunRule.rulesURL)
                            .stStyle(.caption)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Rule \(rule.number)").stStyle(.caption).foregroundStyle(theme.inkSecondary)
                }
            }
        }
        .padding(12)
        .background(STColor.surface, in: shape)
        .overlay { shape.strokeBorder(STColor.rule, lineWidth: 1) }
    }
}

/// Complex Modifications made elsewhere: read, turn on or off, reorder, edit and delete (spec 5.5.3).
struct ComplexRulesSection: View {
    @Bindable var controller: KeyRebinderController
    let openRule: (Int) -> Void

    @State private var deleting: RuleSummary?
    @Environment(\.stTheme) private var theme

    var body: some View {
        let rules = controller.derived.rules
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Complex rules")
            Text("Made in Karabiner-Elements or elsewhere. They run after simple rebinds, top to bottom; the first match wins.")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            if rules.isEmpty {
                Text("This profile has no complex rules.").stStyle(.body).foregroundStyle(theme.inkSecondary)
            }
            ForEach(rules, id: \.index) { rule in
                row(rule, isFirst: rule.index == 0, isLast: rule.index == rules.count - 1)
            }
        }
        .disabled(!controller.canEdit || controller.isBusy)
        .confirmationDialog(
            "Delete the rule \u{201C}\(deleting.map(name(of:)) ?? "")\u{201D}?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { rule in
            Button("Delete", role: .destructive) { Task { await controller.deleteRule(rule.index) } }
        } message: { _ in
            Text("A backup of karabiner.json is made first.")
        }
    }

    private func row(_ rule: RuleSummary, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            STSwitch(isOn: Binding(
                get: { rule.isEnabled },
                set: { enabled in Task { await controller.setRuleEnabled(rule.index, enabled: enabled) } }), label: name(of: rule))
            VStack(alignment: .leading, spacing: 2) {
                Text(name(of: rule)).stStyle(.body).foregroundStyle(rule.isEnabled ? STColor.ink : theme.inkTertiary)
                Text(rule.isBasicOneToOne ? "Key swaps" : "Edited as JSON").stStyle(.caption).foregroundStyle(theme.inkTertiary)
            }
            Spacer(minLength: 8)
            Button("Edit\u{2026}") { openRule(rule.index) }.buttonStyle(STButtonStyle(.quiet))
            Button { Task { await controller.moveRule(from: rule.index, to: rule.index - 1) } } label: { Image(systemName: "chevron.up") }
                .buttonStyle(STButtonStyle(.quiet)).disabled(isFirst).accessibilityLabel("Move up")
            Button { Task { await controller.moveRule(from: rule.index, to: rule.index + 1) } } label: { Image(systemName: "chevron.down") }
                .buttonStyle(STButtonStyle(.quiet)).disabled(isLast).accessibilityLabel("Move down")
            Button("Delete\u{2026}") { deleting = rule }.buttonStyle(STButtonStyle(.quiet))
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(STColor.rule).frame(height: 1) }
    }

    private func name(of rule: RuleSummary) -> String {
        rule.description.isEmpty ? "Unnamed rule" : rule.description
    }
}
