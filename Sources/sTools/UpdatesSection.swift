import STDesign
import STPlatform
import SwiftUI

/// Settings ▸ Updates (spec 6.2, 6.3): this copy's version, the two switches, Check Now and when sTools last checked.
struct UpdatesSection: View {
    let model: AppModel

    private var center: UpdateCenter { model.updateCenter }
    private var installer: DMGInstaller { model.dmgInstaller }
    @State private var isDropTargeted = false

    var body: some View {
        PageSectionTitle("Updates").padding(.top, 28).padding(.bottom, 4)
        Text(center.version.text)
            .stStyle(.body)
            .foregroundStyle(STColor.ink)
            .textSelection(.enabled)
            .padding(.bottom, 4)
        STSettingsRow("Automatically check for updates") {
            STSwitch(isOn: model.updatesBinding(\.checksAutomatically), label: "Automatically check for updates")
        }
        STSettingsRow("Automatically download and install updates") {
            // Sparkle downloads by itself only on its own checks.
            STSwitch(isOn: model.updatesBinding(\.installsAutomatically), label: "Automatically download and install updates")
                .disabled(!model.updates.checksAutomatically)
        }
        STSettingsRow("Check for updates", showsRule: false) {
            Button(center.phase == .checking ? "Checking\u{2026}" : "Check Now") { center.checkNow() }
                .buttonStyle(STButtonStyle(.secondary))
                .disabled(!center.canCheck)
        }
        VStack(alignment: .leading, spacing: 2) {
            if let status = center.statusText {
                Text(status)
                    .stStyle(.caption)
                    .foregroundStyle(STColor.ink)
                    .transition(.opacity)
            }
            Text(center.unavailableReason ?? center.lastCheckText)
                .stStyle(.caption)
                .foregroundStyle(model.theme.inkSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .stAnimation(STMotion.quick, value: center.statusText)
        STSettingsRow("Install from a DMG", showsRule: false) {
            HStack(spacing: 8) {
                if case .confirmOlder = installer.phase {
                    Button("Cancel") { installer.dismiss() }
                        .buttonStyle(STButtonStyle(.secondary))
                    Button("Install Older Build") { Task { await installer.confirmOlder() } }
                        .buttonStyle(STButtonStyle(.secondary))
                } else {
                    Button(installer.isBusy ? "Installing\u{2026}" : "Install from DMG\u{2026}") { installer.chooseAndInstall() }
                        .buttonStyle(STButtonStyle(.secondary))
                        .disabled(installer.isBusy)
                }
            }
        }
        .padding(.top, 12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(STColor.gold, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .opacity(isDropTargeted ? 1 : 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let dmg = urls.first(where: { $0.pathExtension.lowercased() == "dmg" }), !installer.isBusy else { return false }
            Task { await installer.install(from: dmg) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        Text(installer.statusText ?? "Downloaded a newer sTools? Choose its DMG, or drop it here, and sTools installs it and opens again.")
            .stStyle(.caption)
            .foregroundStyle(isFailure ? STColor.danger : model.theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .stAnimation(STMotion.quick, value: installer.statusText)
    }

    private var isFailure: Bool {
        if case .failed = installer.phase { return true }
        return false
    }
}
