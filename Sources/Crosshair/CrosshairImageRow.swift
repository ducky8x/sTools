import AppKit
import SwiftUI
import STDesign

struct CrosshairImageRow: View {
    @Bindable var controller: CrosshairController

    private static let anchors: [STSegmentedOption<CrosshairSettings.ImageAnchor>] = [
        .init(.center, "Center"), .init(.topLeft, "Top left"), .init(.topRight, "Top right"),
        .init(.bottomLeft, "Bottom left"), .init(.bottomRight, "Bottom right"),
    ]

    var body: some View {
        Group {
            STSettingsRow("Image", showsRule: false) {
                Button("Choose image…") { chooseImage() }
                    .buttonStyle(STButtonStyle(.secondary))
            }
            if let error = controller.imageImportError {
                Text(error).stStyle(.caption).foregroundStyle(STColor.danger)
            }
            STSettingsRow("Image scale") {
                STSlider(value: scaleBinding, in: 10...400, label: "Image scale", valueText: { "\(Int($0))%" })
            }
            STSettingsRow("Image anchor", combinesForAccessibility: false) {
                STSegmented(selection: $controller.settings.imageAnchor, options: Self.anchors)
            }
        }
    }

    private var scaleBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.imageScalePercent) }, set: { controller.settings.imageScalePercent = Int($0.rounded()) })
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.importImage(from: url)
        }
    }
}
