import STDesign
import STPlatform
import SwiftUI

/// Home: an at-a-glance status of every tool and dependency.
struct HomePage: View {
    /// The strip shown while Accessibility isn't allowed: every tool that needs it (rule R10), in sidebar order.
    nonisolated static var accessibilityWarning: String {
        let titles = ToolID.allCases.filter(\.requiresAccessibility).map(\.title)
        let list = titles.dropLast().joined(separator: ", ") + " and " + (titles.last ?? "")
        return "Allow Accessibility to turn on \(list)."
    }

    let model: AppModel

    var body: some View {
        PageContainer {
            STPageHeader(title: "Home", tagline: "Tool statuses and dependencies") { EmptyView() }
            PageSectionTitle("Tools").padding(.top, 28).padding(.bottom, 4)
            ForEach(ToolID.allCases) { tool in
                HomeToolRow(model: model, tool: tool)
            }
            PageSectionTitle("Dependencies").padding(.top, 28).padding(.bottom, 10)
            dependencies
        }
        .pollsPermissions(model.permissions)
    }

    @ViewBuilder private var dependencies: some View {
        if model.accessibilityGranted {
            STSettingsRow("Accessibility") {
                HStack(spacing: 8) {
                    STSeal(isStamped: true)
                    Text("Allowed").stStyle(.body).foregroundStyle(STColor.ink)
                }
            }
        } else {
            STRequirementStrip(
                kind: .warning,
                message: Self.accessibilityWarning,
                actionTitle: "Allow\u{2026}",
                action: { Task { await model.allowAccessibility() } })
            .padding(.bottom, 4)
        }
        minecraftRow
    }

    @ViewBuilder private var minecraftRow: some View {
        let text = MinecraftStatusText.make(
            active: model.minecraft.active,
            others: Array(model.minecraft.instances.dropFirst()),
            conflict: model.minecraft.conflict,
            displays: model.displays.displays,
            accessibilityGranted: model.accessibilityGranted)
        if MinecraftStatusText.isConflict(model.minecraft.conflict) {
            STRequirementStrip(kind: .warning, message: text).padding(.top, 8)
        } else {
            STSettingsRow("Minecraft") {
                Text(text)
                    .stStyle(.body)
                    .foregroundStyle(STColor.ink)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
