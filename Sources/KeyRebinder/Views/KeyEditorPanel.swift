import STDesign
import SwiftUI

/// The selected key: what it sends now, choosing what it should send (spec 5.5.3), and the sTools hotkeys on it.
struct KeyEditorPanel: View {
    @Bindable var controller: KeyRebinderController
    let key: KarabinerEvent
    /// Whether the panel shows sTools hotkeys: their findings, the Becomes captions about them and the Hotkeys
    /// part. False in the Prologue's trial.
    let showsHotkeys: Bool
    /// Opens Home ▸ Hotkeys, from a key a rule drives; nil leaves Open Hotkeys out.
    let openHotkeys: (() -> Void)?
    let openRule: (Int) -> Void
    /// Opens the Hotkeys part's editor with these choices on whichever key the panel shows. Tests and previews only;
    /// the page passes nil.
    private let hotkeyDraft: HotkeyDraft?

    @State private var chosen: KarabinerEvent?
    @State private var showsPicker = false
    @Environment(\.stTheme) private var theme

    init(
        controller: KeyRebinderController, key: KarabinerEvent, showsHotkeys: Bool = true,
        openHotkeys: (() -> Void)? = nil, hotkeyDraft: HotkeyDraft? = nil, openRule: @escaping (Int) -> Void
    ) {
        self.controller = controller
        self.key = key
        self.showsHotkeys = showsHotkeys
        self.openHotkeys = openHotkeys
        self.hotkeyDraft = hotkeyDraft
        self.openRule = openRule
    }

    private var binding: EffectiveBinding? { controller.binding(for: key) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(KeyNames.name(for: key)).stStyle(.sectionTitle).foregroundStyle(STColor.ink)
                Spacer()
                Button("Close") { controller.selectedKey = nil }.buttonStyle(STButtonStyle(.quiet))
            }
            Text(statusLine).stStyle(.body).foregroundStyle(theme.inkSecondary)
            if !actions.isEmpty {
                Text("In Minecraft: \(actions.joined(separator: ", "))").stStyle(.body).foregroundStyle(theme.inkSecondary)
            }
            ForEach(Self.findings(for: key, controller: controller, showsHotkeys: showsHotkeys)) { finding in
                Label(finding.message, systemImage: "circle.fill")
                    .labelStyle(FindingLabelStyle())
                    .stStyle(.caption)
                    .foregroundStyle(STColor.ink)
            }
            editing
            if showsHotkeys && controller.showsHotkeyLayer {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
                Text("Hotkeys").stStyle(.label).foregroundStyle(theme.inkSecondary).accessibilityAddTraits(.isHeader)
                // A new identity per key and per key code it sends: selecting another key, or a change to what this
                // key sends, closes the editor unsaved.
                KeyHotkeysBlock(controller: controller, key: key, chosen: $chosen, openHotkeys: openHotkeys, draft: hotkeyDraft)
                    .id(KeyHotkeysBlock.identity(of: key, controller: controller))
            }
        }
        .padding(18)
        .background(STColor.surface, in: shape)
        .overlay { shape.strokeBorder(STColor.rule, lineWidth: 1) }
        .onChange(of: controller.capturedOutput) { _, captured in
            guard let captured else { return }
            chosen = captured
            controller.capturedOutput = nil
        }
        .onChange(of: key) {
            chosen = nil
            controller.isCapturingOutput = false
        }
        .onDisappear { controller.isCapturingOutput = false }
    }

    @ViewBuilder private var editing: some View {
        if let binding, !binding.isDrawable, case .complex(let index, _) = binding.source {
            Button("Open Rule\u{2026}") { openRule(index) }.buttonStyle(STButtonStyle(.secondary))
        } else if !controller.canEdit {
            Text("Editing needs Karabiner-Elements running and ready (see above).")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Becomes").stStyle(.label).foregroundStyle(theme.inkSecondary)
                    Text(chosen.map { KeyNames.name(for: $0) } ?? "\u{2014}")
                        .stStyle(.body).foregroundStyle(chosen == nil ? theme.inkTertiary : theme.accent)
                        .frame(minWidth: 90, alignment: .leading)
                    Button(controller.isCapturingOutput ? "Press a key\u{2026}" : "Press") { controller.isCapturingOutput.toggle() }
                        .buttonStyle(STButtonStyle(.secondary))
                        .help("Press the key (or mouse button 3 and up) it should become.")
                    Button("Choose\u{2026}") { showsPicker = true }
                        .buttonStyle(STButtonStyle(.secondary))
                        .popover(isPresented: $showsPicker) {
                            KeyPicker { picked in
                                chosen = picked
                                showsPicker = false
                            }
                            .stMotionRoot(theme)
                        }
                }
                if KeyTable.shared.entry(for: key)?.isUnsafeSource == true {
                    Text("Rebinding the left button can leave you unable to click. Keep a trackpad or another mouse at hand.")
                        .stStyle(.caption).foregroundStyle(STColor.danger)
                }
                HStack(spacing: 10) {
                    Button("Save") {
                        guard let output = chosen else { return }
                        Task {
                            await controller.setRebind(key, to: output)
                            chosen = nil
                        }
                    }
                    .buttonStyle(STButtonStyle(.primary))
                    .disabled(chosen == nil || controller.isBusy)
                    if hasSimpleRebind {
                        Button("Remove Rebind") { Task { await controller.removeRebind(key) } }
                            .buttonStyle(STButtonStyle(.secondary))
                            .disabled(controller.isBusy)
                    }
                }
                ForEach(Self.hotkeyCaptions(for: key, chosen: chosen, controller: controller, showsHotkeys: showsHotkeys), id: \.self) { caption in
                    Text(caption)
                        .stStyle(.caption)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Saved to the profile\u{2019}s Simple Modifications for \(scopeName). Choosing the key itself removes its rebind.")
                    .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            }
        }
    }

    /// The findings on `key`: the rule checker's, then, when the panel shows hotkeys, the hotkeys'.
    static func findings(for key: KarabinerEvent, controller: KeyRebinderController, showsHotkeys: Bool) -> [CheckerFinding] {
        controller.findings(for: key) + (showsHotkeys ? controller.hotkeyFindings(for: key) : [])
    }

    /// What the rebind would do to sTools hotkeys, under Becomes: for the output `chosen`, or with nothing chosen,
    /// for Remove Rebind when the key has a rebind to remove (those name Remove Rebind, since they sit right under
    /// what the key sends now). Hotkeys never move with a rebind.
    static func hotkeyCaptions(
        for key: KarabinerEvent, chosen: KarabinerEvent?, controller: KeyRebinderController, showsHotkeys: Bool
    ) -> [String] {
        guard showsHotkeys else { return [] }
        if let chosen { return controller.rebindHotkeyNotes(for: key, becoming: chosen) }
        return hasSimpleRebind(key, controller: controller) ? controller.rebindHotkeyNotes(for: key, becoming: nil) : []
    }

    private var actions: [String] {
        EffectiveMapping.output(of: key, in: controller.derived.bindings).map(controller.minecraftActions(for:)) ?? []
    }

    private var hasSimpleRebind: Bool { Self.hasSimpleRebind(key, controller: controller) }

    private static func hasSimpleRebind(_ key: KarabinerEvent, controller: KeyRebinderController) -> Bool {
        let aliases = KeyTable.shared.aliases(of: key)
        return controller.derived.rebinds.contains { aliases.contains($0.from) }
    }

    private var scopeName: String {
        controller.settings.scopeDevice == nil ? "all devices" : "this device"
    }

    private var statusLine: String {
        guard let binding else { return "Not rebound." }
        switch (binding.source, binding.isDrawable, binding.output) {
        case (.simple, true, let output?):
            return "Sends \(KeyNames.name(for: output)), through a simple rebind."
        case (.complex(_, let description), true, let output?):
            return "Sends \(KeyNames.name(for: output)), through the rule \u{201C}\(description)\u{201D}."
        case (.complex(_, let description), _, _):
            return "Driven by the rule \u{201C}\(description)\u{201D}, which the keyboard can\u{2019}t draw simply."
        default:
            return "Sends several keys at once, through a simple rebind."
        }
    }
}

/// A small red dot before a checker message.
struct FindingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(STColor.danger)
            configuration.title
        }
    }
}
