import STDesign
import STPlatform
import SwiftUI

/// Everything below the page header for the Window Backdrop tool: the live preview plate, the fill for
/// Minecraft's own display, the other-displays list, then an Advanced section (spec 5.2.4).
public struct BackdropSettingsView: View {
    @Bindable private var controller: BackdropController
    @State private var advancedExpanded = false
    @State private var isResetConfirming = false

    public init(controller: BackdropController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            STPlate {
                BackdropFillView(fill: controller.settings.fill, image: controller.image(for: controller.settings.fill))
                    .overlay { MinecraftWindowSketch() }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(10)
            }

            VStack(alignment: .leading, spacing: 0) {
                BackdropFillEditor(
                    fill: $controller.settings.fill,
                    onImportImage: { controller.importImage(from: $0) },
                    image: controller.image(for: controller.settings.fill),
                    importError: controller.imageImportError)
            }

            if !otherDisplays.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Other displays").stStyle(.label)
                    ForEach(otherDisplays) { display in
                        BackdropOtherDisplayRow(controller: controller, display: display)
                    }
                }
            }

            STAdvancedDisclosure(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    STSettingsRow("Opacity") {
                        STSlider(value: opacityBinding, in: 10...100, label: "Opacity", valueText: { "\(Int($0))%" })
                    }
                    STChoiceRow("Hide on full screen") {
                        STSegmented(selection: $controller.settings.hideOnFullScreenScope, options: [
                            .init(.thisDisplay, "This display"), .init(.allDisplays, "All displays"),
                        ])
                    }
                    STSettingsRow("Fill transition") {
                        STSlider(value: $controller.settings.fillTransitionSeconds, in: BackdropSettings.fillTransitionRange, step: 0.05,
                                 label: "Fill transition", valueText: { $0 == 0 ? "Instant" : String(format: "%.2f s", $0) })
                    }
                    STSettingsRow("Show only while Minecraft is focused") {
                        STSwitch(isOn: $controller.settings.hidesWhenMinecraftNotFocused, label: "Show only while Minecraft is focused")
                    }
                    STSettingsRow("Reset", showsRule: false) {
                        Button("Reset to default\u{2026}") { isResetConfirming = true }
                            .buttonStyle(STButtonStyle(.secondary))
                    }
                }
            }
        }
        .confirmationDialog(
            "Reset Window Backdrop to default?", isPresented: $isResetConfirming, titleVisibility: .visible,
            actions: {
                Button("Reset to Default", role: .destructive) { controller.resetToDefault() }
                Button("Cancel", role: .cancel) {}
            },
            message: { Text("This sets every Window Backdrop setting back to its default.") })
    }

    private var otherDisplays: [DisplayInfo] {
        controller.availableDisplays.filter { $0.id != controller.minecraftDisplayID }
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.opacityPercent) }, set: { controller.settings.opacityPercent = Int($0.rounded()) })
    }
}

private struct BackdropOtherDisplayRow: View {
    @Bindable var controller: BackdropController
    let display: DisplayInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            STSettingsRow(display.name, showsRule: !isExpanded) {
                HStack(spacing: 12) {
                    if controller.isCovered(displayID: display.id) {
                        Button(isExpanded ? "Hide fill" : "Edit fill") { isExpanded.toggle() }
                            .buttonStyle(STButtonStyle(.secondary))
                    }
                    STSwitch(isOn: coveredBinding, label: "Cover \(display.name)")
                }
            }
            if isExpanded, controller.isCovered(displayID: display.id) {
                VStack(alignment: .leading, spacing: 0) {
                    BackdropFillEditor(
                        fill: fillBinding,
                        onImportImage: { controller.importImage(from: $0, forDisplayID: display.id) },
                        image: controller.image(for: controller.settings.fill(for: display.id)),
                        importError: controller.imageImportError(for: display.id))
                }
                .padding(.leading, 12)
            }
        }
    }

    private var coveredBinding: Binding<Bool> {
        Binding(
            get: { controller.isCovered(displayID: display.id) },
            set: { covered in
                controller.setCovered(covered, displayID: display.id)
                if !covered { isExpanded = false }
            })
    }

    private var fillBinding: Binding<BackdropSettings.Fill> {
        Binding(
            get: { controller.settings.fill(for: display.id) },
            set: { controller.setDisplayFill($0, for: display.id) })
    }
}

/// A stand-in for the Minecraft window in the preview, so the fill reads as the stage around the game rather
/// than a plain swatch.
private struct MinecraftWindowSketch: View {
    @Environment(\.stTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(STColor.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.stroke, lineWidth: 1)
                }
                .overlay {
                    Text("Minecraft")
                        .stStyle(.label)
                        .foregroundStyle(STColor.inkTertiary)
                }
                .frame(width: proxy.size.width * 0.42, height: proxy.size.height * 0.64)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
