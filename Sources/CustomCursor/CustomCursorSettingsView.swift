import AppKit
import STDesign
import SwiftUI

/// Everything below the page header for the Custom Cursor tool (spec 5.7.4): the preview plate with its caption, then
/// the settings. Without the calls the tool needs, a strip says it can't change the pointer here.
public struct CustomCursorSettingsView: View {
    @Bindable private var controller: CustomCursorController
    @Environment(\.stTheme) private var theme
    @Environment(\.displayScale) private var displayScale

    public init(controller: CustomCursorController) {
        self.controller = controller
    }

    /// The page's words, gathered here.
    public enum Copy {
        public static let notSupported = "Custom Cursor can\u{2019}t change the pointer on this version of macOS, so it stays off."
        public static let otherApps = "When sTools puts your arrow back, it can also reset pointers another cursor app such as "
            + "Mousecape changed. Apply them again from that app."
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !controller.isSupported {
                STRequirementStrip(kind: .error, message: Copy.notSupported)
            }
            VStack(alignment: .leading, spacing: 8) {
                STPlate {
                    CursorPreview(cursor: controller.preview(scale: scale), scale: CGFloat(scale))
                }
                Text(Copy.otherApps)
                    .stStyle(.caption)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                STChoiceRow("Shape") {
                    STSegmented(selection: $controller.settings.shape, options: Self.shapes)
                }
                if controller.settings.shape == .image {
                    CursorImageRows(controller: controller)
                } else {
                    CursorShapeRows(settings: $controller.settings)
                }
                STChoiceRow("Where", showsRule: false) {
                    STSegmented(selection: $controller.settings.where, options: Self.places)
                }
            }
        }
    }

    /// The display's scale, as a whole number: the image macOS would use here.
    private var scale: Int { max(1, Int(displayScale.rounded())) }

    static let shapes: [STSegmentedOption<CustomCursorSettings.Shape>] = [
        .init(.plus, "Plus"), .init(.dot, "Dot"), .init(.circle, "Circle"), .init(.x, "X"), .init(.image, "Image"),
    ]

    static let places: [STSegmentedOption<CustomCursorSettings.Where>] =
        CustomCursorSettings.Where.allCases.map { .init($0, $0.title) }
}

/// A shape's colors and size. Thickness is for the shapes drawn with a line: Plus, X and Circle.
struct CursorShapeRows: View {
    @Binding var settings: CustomCursorSettings

    var body: some View {
        Group {
            STSettingsRow("Fill color") { STColorWell(hex: $settings.fillHex, label: "Fill color") }
            STSettingsRow("Outline") { STSwitch(isOn: $settings.outlineEnabled, label: "Outline") }
            if settings.outlineEnabled {
                STSettingsRow("Outline color") { STColorWell(hex: $settings.outlineHex, label: "Outline color") }
            }
            STSettingsRow("Size") {
                STSlider(value: binding(\.size), in: range(CustomCursorSettings.sizeRange), label: "Size")
            }
            if settings.shape != .dot {
                STSettingsRow("Thickness") {
                    STSlider(value: binding(\.thickness), in: range(CustomCursorSettings.thicknessRange), label: "Thickness")
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<CustomCursorSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(settings[keyPath: keyPath]) }, set: { settings[keyPath: keyPath] = Int($0.rounded()) })
    }

    private func range(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }
}

/// The Image shape's rows: choosing the image, its scale and the point that clicks.
struct CursorImageRows: View {
    @Bindable var controller: CustomCursorController

    static let clickPoints: [STSegmentedOption<CustomCursorSettings.ClickPoint>] =
        CustomCursorSettings.ClickPoint.allCases.map { .init($0, $0.title) }

    var body: some View {
        Group {
            STSettingsRow("Image", showsRule: false) {
                Button("Choose image\u{2026}") { chooseImage() }
                    .buttonStyle(STButtonStyle(.secondary))
            }
            if let error = controller.imageImportError {
                Text(error).stStyle(.caption).foregroundStyle(STColor.danger)
            }
            STSettingsRow("Image scale") {
                STSlider(value: scaleBinding, in: 10...400, label: "Image scale", valueText: { "\(Int($0))%" })
            }
            STChoiceRow("Click point") {
                STSegmented(selection: $controller.settings.clickPoint, options: Self.clickPoints)
            }
        }
    }

    private var scaleBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.imageScalePercent) },
                set: { controller.settings.imageScalePercent = Int($0.rounded()) })
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
