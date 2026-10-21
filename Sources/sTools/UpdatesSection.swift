import STDesign
import STPlatform
import SwiftUI

/// Settings ▸ Updates (spec 6.2, 6.3): this copy's version, the two switches, Check Now and when sTools last checked.
struct UpdatesSection: View {
    let model: AppModel

    private var center: UpdateCenter { model.updateCenter }

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
    }
}
