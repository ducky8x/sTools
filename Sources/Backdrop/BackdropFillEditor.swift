import AppKit
import STDesign
import SwiftUI
import UniformTypeIdentifiers

/// Editor for one `BackdropSettings.Fill`: the fill-kind picker and whichever controls that kind needs.
/// Shared by the main (Minecraft display) fill and any per-display override.
struct BackdropFillEditor: View {
    @Binding var fill: BackdropSettings.Fill
    /// Imports an image for this fill and reports the stored relative name back.
    var onImportImage: (URL) -> Void
    /// Imports a GIF or video for this fill.
    var onImportAnimation: (URL) -> Void
    var image: CGImage?
    var importError: String?
    /// Why the chosen GIF or video can't be used or played, if it can't.
    var animationError: String?

    private static let kindOptions: [STSegmentedOption<BackdropSettings.FillKind>] = [
        .init(.color, "Color"), .init(.linearGradient, "Linear"), .init(.radialGradient, "Radial"), .init(.image, "Image"),
        .init(.animated, "Animated"),
    ]

    private static let contentModeOptions: [STSegmentedOption<BackdropSettings.ImageContentMode>] = [
        .init(.fill, "Fill"), .init(.fit, "Fit"), .init(.stretch, "Stretch"), .init(.center, "Center"),
    ]

    var body: some View {
        Group {
            STSettingsRow("Fill type", combinesForAccessibility: false) {
                STSegmented(selection: $fill.kind, options: Self.kindOptions)
            }
            switch fill.kind {
            case .color:
                STSettingsRow("Color") { STColorWell(hex: $fill.color, label: "Color") }
            case .linearGradient:
                STSettingsRow("Start color") { STColorWell(hex: $fill.gradientStartColor, label: "Start color") }
                STSettingsRow("End color") { STColorWell(hex: $fill.gradientEndColor, label: "End color") }
                STSettingsRow("Angle") {
                    STSlider(value: $fill.gradientAngleDegrees, in: 0...359, label: "Angle", valueText: { "\(Int($0))°" })
                }
            case .radialGradient:
                STSettingsRow("Start color") { STColorWell(hex: $fill.gradientStartColor, label: "Start color") }
                STSettingsRow("End color") { STColorWell(hex: $fill.gradientEndColor, label: "End color") }
                STSettingsRow("Radius") {
                    STSlider(value: $fill.gradientRadius, in: 0.05...2, label: "Radius", valueText: { "\(Int($0 * 100))%" })
                }
            case .image:
                STSettingsRow("Image", showsRule: false) {
                    Button("Choose image…") { chooseImage() }
                        .buttonStyle(STButtonStyle(.secondary))
                }
                if let importError {
                    Text(importError).stStyle(.caption).foregroundStyle(STColor.danger)
                }
                fitRows
            case .animated:
                STSettingsRow("Animation", showsRule: false) {
                    Button("Choose GIF or video…") { chooseAnimation() }
                        .buttonStyle(STButtonStyle(.secondary))
                }
                if let animationError {
                    Text(animationError).stStyle(.caption).foregroundStyle(STColor.danger)
                }
                STNoteLine(Self.animationNote)
                fitRows
            }
        }
    }

    /// Fit, and the color behind it where the picture doesn't cover the display: an image and an animation fit alike.
    @ViewBuilder
    private var fitRows: some View {
        STSettingsRow("Fit", combinesForAccessibility: false) {
            STSegmented(selection: $fill.imageContentMode, options: Self.contentModeOptions)
        }
        if fill.imageContentMode == .fit || fill.imageContentMode == .center {
            STSettingsRow("Background", showsRule: false) {
                STColorWell(hex: $fill.imageBackgroundColor, label: "Background color")
            }
        }
    }

    /// Under the Animated fill's rows (spec 5.2.3, 9.3): what it does, and what it costs.
    static let animationNote = "Plays in a loop with no sound, and stops while the backdrop is hidden. The preview shows the first frame."

    private func chooseAnimation() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.gif, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onImportAnimation(url)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onImportImage(url)
    }
}
