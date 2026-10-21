import STDesign
import STPlatform
import SwiftUI

/// Home: an at-a-glance status of every tool and dependency.
struct HomePage: View {
    let model: AppModel

    var body: some View {
        PageContainer(anchor: Binding(get: { model.pendingPageAnchor }, set: { model.pendingPageAnchor = $0 })) {
            STPageHeader(title: "Home", tagline: "Every tool and what it needs, at a glance.") { EmptyView() }
            PageSectionTitle("Tools").padding(.top, 28).padding(.bottom, 4)
            ForEach(ToolID.allCases) { tool in
                HomeToolRow(model: model, tool: tool)
            }
            PageSectionTitle("Dependencies").padding(.top, 28).padding(.bottom, 10)
            dependencies
            HotkeysSection(model: model)
                .id(PageAnchor.hotkeys)
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
                message: "Accessibility isn't allowed yet, so NBB Overlay, Window Backdrop, Crosshair and Screen Recording stay off.",
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
