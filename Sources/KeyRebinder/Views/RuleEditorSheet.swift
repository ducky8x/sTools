import AppKit
import STDesign
import SwiftUI

/// Identifies the rule a sheet edits.
struct RuleSheetItem: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Edits one complex rule: a form when it only swaps keys, otherwise its JSON, checked with
/// `karabiner_cli --lint-complex-modifications` before it can be saved (spec 5.5.3).
struct RuleEditorSheet: View {
    @Bindable var controller: KeyRebinderController
    let index: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.stTheme) private var theme
    @State private var showsJSON = false
    @State private var text = ""
    @State private var lint: KeyRebinderController.LintOutcome?
    @State private var lintedText: String?
    @State private var isChecking = false
    @State private var picking: Int?

    private var summary: RuleSummary? { controller.derived.rules.first { $0.index == index } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.map { $0.description.isEmpty ? "Unnamed rule" : $0.description } ?? "Rule")
                .stStyle(.sectionTitle).foregroundStyle(STColor.ink)
            if summary?.isBasicOneToOne == true && !showsJSON {
                form
            } else {
                json
            }
            Spacer(minLength: 0)
            HStack {
                if summary?.isBasicOneToOne == true && !showsJSON {
                    Button("Edit as JSON") { showsJSON = true }.buttonStyle(STButtonStyle(.quiet))
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(STButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 540)
        .background(STColor.background)
        .onAppear { text = controller.ruleText(index) ?? "" }
    }

    private var form: some View {
        let swaps = controller.rule(at: index).map(RebindEditor.plainSwaps(in:)) ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("Each line is one key swap. Changes are saved as you make them.")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            ForEach(swaps, id: \.manipulator) { swap in
                HStack(spacing: 12) {
                    Text(KeyNames.name(for: swap.from)).stStyle(.body).foregroundStyle(STColor.ink).frame(width: 160, alignment: .leading)
                    Text("\u{2192}").foregroundStyle(theme.inkTertiary)
                    Button(KeyNames.name(for: swap.to)) { picking = swap.manipulator }
                        .buttonStyle(STButtonStyle(.secondary))
                        .disabled(!controller.canEdit || controller.isBusy)
                        .popover(isPresented: Binding(get: { picking == swap.manipulator }, set: { if !$0 { picking = nil } })) {
                            KeyPicker { picked in
                                picking = nil
                                Task { await controller.setRuleOutput(rule: index, manipulator: swap.manipulator, to: picked) }
                            }
                        }
                }
            }
        }
    }

    private var json: some View {
        VStack(alignment: .leading, spacing: 10) {
            CodeEditor(text: $text)
                .frame(minHeight: 300)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(STColor.rule, lineWidth: 1) }
            switch lint {
            case .invalid(let messages)? where lintedText == text:
                ForEach(messages, id: \.self) { message in
                    Text(message).stStyle(.caption).foregroundStyle(STColor.danger).fixedSize(horizontal: false, vertical: true)
                }
            case .valid? where lintedText == text:
                Text("Karabiner-Elements accepts this rule.").stStyle(.caption).foregroundStyle(STColor.success)
            default:
                Text("Check the rule with Karabiner-Elements before saving.").stStyle(.caption).foregroundStyle(theme.inkTertiary)
            }
            HStack(spacing: 10) {
                Button(isChecking ? "Checking\u{2026}" : "Check") {
                    let checked = text
                    isChecking = true
                    Task {
                        lint = await controller.lint(ruleText: checked)
                        lintedText = checked
                        isChecking = false
                    }
                }
                .buttonStyle(STButtonStyle(.secondary))
                .disabled(isChecking || !controller.canEdit)
                Button("Save") {
                    guard case .valid(let rule)? = lint, lintedText == text else { return }
                    Task {
                        await controller.replaceRule(index, with: rule)
                        dismiss()
                    }
                }
                .buttonStyle(STButtonStyle(.primary))
                .disabled(!isSavable || controller.isBusy)
            }
        }
    }

    private var isSavable: Bool {
        guard case .valid? = lint else { return false }
        return lintedText == text && controller.canEdit
    }
}

/// A plain-text editor for JSON: monospaced, and with smart quotes, dashes and spelling fixes off, since any
/// of them would quietly break the JSON.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(STColor.ink)
        textView.backgroundColor = NSColor(STColor.raised)
        textView.insertionPointColor = NSColor(STColor.gold)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Rule JSON")
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
