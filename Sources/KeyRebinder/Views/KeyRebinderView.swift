import AppKit
import STDesign
import SwiftUI

/// Everything below the Key Rebinder's page header (spec 5.5).
public struct KeyRebinderView: View {
    @Bindable private var controller: KeyRebinderController
    @State private var ruleBeingEdited: RuleSheetItem?
    @State private var monitor = KeyEventMonitor()
    @Environment(\.stTheme) private var theme

    public init(controller: KeyRebinderController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            strips
            if let layout = controller.layout {
                KeyboardPlate(controller: controller, layout: layout)
                if let key = controller.selectedKey {
                    KeyEditorPanel(controller: controller, key: key) { ruleBeingEdited = RuleSheetItem(index: $0) }
                }
                if controller.config != nil {
                    if controller.settings.checkerEnabled { FindingsSection(controller: controller) }
                    FnKeysSection(controller: controller)
                    ComplexRulesSection(controller: controller) { ruleBeingEdited = RuleSheetItem(index: $0) }
                }
            } else {
                LayoutChooser(controller: controller)
            }
            KeyRebinderSettingsSection(controller: controller)
        }
        .task { await controller.refresh() }
        .onAppear {
            controller.startWatching()
            monitor.start(route)
        }
        .onDisappear {
            monitor.stop()
            controller.stopWatching()
            controller.isTesting = false
            controller.isCapturingOutput = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refresh() }
        }
        .sheet(item: $ruleBeingEdited) { item in
            RuleEditorSheet(controller: controller, index: item.index)
        }
    }

    // MARK: Status

    @ViewBuilder private var strips: some View {
        if let requirement = controller.requirement, !requirement.isReady {
            STRequirementStrip(kind: .warning, message: requirement.fixText, actionTitle: actionTitle(for: requirement)) {
                act(on: requirement)
            }
        }
        if controller.configIsSymbolicLink {
            STRequirementStrip(kind: .warning, message:
                "karabiner.json is a symbolic link. Karabiner-Elements doesn\u{2019}t reload a linked file, so sTools shows it but won\u{2019}t change it.")
        } else if controller.requirement == .ready, let problem = controller.configProblem {
            STRequirementStrip(kind: .error, message: problem, actionTitle: "Check Again") {
                Task { await controller.refresh() }
            }
        }
        if let pending = controller.pendingEdit {
            PendingEditBanner(summary: pending.summary, isBusy: controller.isBusy) {
                Task { await controller.confirmPendingEdit() }
            } discard: {
                Task { await controller.discardPendingEdit() }
            }
        }
        if let error = controller.errorMessage {
            STRequirementStrip(kind: .error, message: error, actionTitle: "Dismiss") { controller.dismissError() }
        }
    }

    private func actionTitle(for requirement: KarabinerRequirement) -> String {
        switch requirement {
        case .notInstalled: "Get Karabiner-Elements\u{2026}"
        case .notRunning, .versionTooOld: "Open Karabiner-Elements"
        case .configUnreadable, .ready: "Check Again"
        }
    }

    private func act(on requirement: KarabinerRequirement) {
        switch requirement {
        case .notInstalled:
            if let url = URL(string: "https://karabiner-elements.pqrs.org/") { NSWorkspace.shared.open(url) }
        case .notRunning, .versionTooOld:
            NSWorkspace.shared.openApplication(at: KarabinerProbes.defaultAppURL, configuration: NSWorkspace.OpenConfiguration())
        case .configUnreadable, .ready:
            Task { await controller.refresh() }
        }
    }

    // MARK: Key presses

    private func route(_ press: KeyPress, _ event: NSEvent) -> Bool {
        let window = event.window
        let isBusy = window?.firstResponder is NSText || window?.sheetParent != nil || window?.isMainWindow == false
        let used = controller.handle(press, commandHeld: event.modifierFlags.contains(.command), isBusy: isBusy)
        // Caps Lock never reports a release, so the tester lets go of it shortly after.
        if controller.isTesting, case .down(let key, _) = press, event.type == .flagsChanged,
           event.keyCode == KeyEventMonitor.capsLockKeyCode {
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                controller.testerReleased(key)
            }
        }
        return used
    }
}

/// `karabiner.json` changed on disk after sTools read it: the plate shows the edit applied to the new file,
/// and nothing is written until the user says so (spec 5.5.3, step 2).
private struct PendingEditBanner: View {
    let summary: String
    let isBusy: Bool
    let save: () -> Void
    let discard: () -> Void

    @Environment(\.stTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text("karabiner.json changed since sTools read it. The keyboard below shows your change (\(summary)) applied to the new file. Nothing is saved yet.")
                .stStyle(.body).foregroundStyle(STColor.ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Save This", action: save).buttonStyle(STButtonStyle(.primary)).disabled(isBusy)
                Button("Discard", action: discard).buttonStyle(STButtonStyle(.secondary)).disabled(isBusy)
            }
        }
        .padding(14)
        .background(STColor.surface, in: shape)
        .overlay { shape.strokeBorder(theme.accentStroke, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}
