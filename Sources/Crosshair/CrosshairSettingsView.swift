import SwiftUI
import STDesign

/// Everything below the page header for the Crosshair tool: the live preview plate, the everyday
/// settings, then an Advanced section for the rest (spec 5.3.2).
public struct CrosshairSettingsView: View {
    @Bindable private var controller: CrosshairController
    @State private var advancedExpanded = false
    @State private var isResetConfirming = false
    @Environment(\.stTheme) private var theme

    public init(controller: CrosshairController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            STPlate {
                CrosshairPreview(settings: controller.settings, customImage: controller.previewImage)
            }

            VStack(alignment: .leading, spacing: 0) {
                CrosshairShapeRow(settings: $controller.settings)
                if controller.settings.shape == .image {
                    CrosshairImageRow(controller: controller)
                } else {
                    CrosshairColorsRow(settings: $controller.settings)
                    CrosshairSizeRow(settings: $controller.settings)
                    if let display = controller.displayPixelSize,
                       let note = CrosshairCentering.note(for: controller.settings, on: display) {
                        Text(note)
                            .stStyle(.caption)
                            .foregroundStyle(theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    }
                }
                CrosshairOffsetRow(settings: $controller.settings)
            }

            STAdvancedDisclosure(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    if controller.settings.shape != .image {
                        STSettingsRow("Gap") {
                            STSlider(value: gapBinding, in: 0...100, label: "Gap", valueText: { "\(Int($0)) px" })
                        }
                    }
                    STSettingsRow("Opacity") {
                        STSlider(value: opacityBinding, in: 10...100, label: "Opacity", valueText: { "\(Int($0))%" })
                    }
                    STSettingsRow("Show only while Minecraft is focused") {
                        STSwitch(isOn: $controller.settings.visibleOnlyWhileMinecraftFocused, label: "Show only while Minecraft is focused")
                    }
                    STSettingsRow("Display") {
                        STSegmented(selection: $controller.settings.displayChoice, options: [
                            .init(.followMinecraft, "Follow Minecraft"), .init(.specific, "A specific display"),
                        ])
                    }
                    STSettingsRow("Reset", showsRule: false) {
                        Button("Reset to default\u{2026}") { isResetConfirming = true }
                            .buttonStyle(STButtonStyle(.secondary))
                    }
                }
            }
        }
        .confirmationDialog(
            "Reset Crosshair to default?", isPresented: $isResetConfirming, titleVisibility: .visible,
            actions: {
                Button("Reset to Default", role: .destructive) { controller.resetToDefault() }
                Button("Cancel", role: .cancel) {}
            },
            message: { Text("This sets every Crosshair setting back to its default.") })
    }

    private var gapBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.gap) }, set: { controller.settings.gap = Int($0.rounded()) })
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.opacityPercent) }, set: { controller.settings.opacityPercent = Int($0.rounded()) })
    }
}
