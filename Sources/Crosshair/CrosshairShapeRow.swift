import SwiftUI
import STDesign

struct CrosshairShapeRow: View {
    @Binding var settings: CrosshairSettings

    private static let options: [STSegmentedOption<CrosshairSettings.Shape>] = [
        .init(.plus, "Plus"), .init(.dot, "Dot"), .init(.circle, "Circle"), .init(.x, "X"), .init(.image, "Image"),
    ]

    var body: some View {
        STSettingsRow("Shape") {
            STSegmented(selection: $settings.shape, options: Self.options)
        }
    }
}

struct CrosshairColorsRow: View {
    @Binding var settings: CrosshairSettings

    var body: some View {
        Group {
            STSettingsRow("Fill color") { STColorWell(hex: $settings.fillHex, label: "Fill color") }
            STSettingsRow("Outline") { STSwitch(isOn: $settings.outlineEnabled, label: "Outline") }
            if settings.outlineEnabled {
                STSettingsRow("Outline color") { STColorWell(hex: $settings.outlineHex, label: "Outline color") }
            }
        }
    }
}

struct CrosshairSizeRow: View {
    @Binding var settings: CrosshairSettings

    var body: some View {
        Group {
            STSettingsRow("Size") {
                STSlider(value: sizeBinding, in: Double(CrosshairSettings.sizeRange.lowerBound)...Double(CrosshairSettings.sizeRange.upperBound), label: "Size")
            }
            STSettingsRow("Thickness") {
                STSlider(value: thicknessBinding, in: Double(CrosshairSettings.thicknessRange.lowerBound)...Double(CrosshairSettings.thicknessRange.upperBound), label: "Thickness")
            }
        }
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { Double(settings.size) }, set: { settings.size = Int($0.rounded()) })
    }

    private var thicknessBinding: Binding<Double> {
        Binding(get: { Double(settings.thickness) }, set: { settings.thickness = Int($0.rounded()) })
    }
}

struct CrosshairOffsetRow: View {
    @Binding var settings: CrosshairSettings

    var body: some View {
        Group {
            STSettingsRow("Offset X") {
                STSlider(value: xBinding, in: -500...500, label: "Offset X", valueText: { "\(Int($0)) px" })
            }
            STSettingsRow("Offset Y") {
                STSlider(value: yBinding, in: -500...500, label: "Offset Y", valueText: { "\(Int($0)) px" })
            }
        }
    }

    private var xBinding: Binding<Double> {
        Binding(get: { Double(settings.offsetX) }, set: { settings.offsetX = Int($0.rounded()) })
    }

    private var yBinding: Binding<Double> {
        Binding(get: { Double(settings.offsetY) }, set: { settings.offsetY = Int($0.rounded()) })
    }
}
