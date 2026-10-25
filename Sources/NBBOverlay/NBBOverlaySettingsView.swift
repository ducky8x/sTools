import STDesign
import SwiftUI

/// Everything below the page header for the NBB Overlay tool: reachability, the live preview plate,
/// the everyday settings, then an Advanced section (spec 5.1.5).
public struct NBBOverlaySettingsView: View {
    @Bindable private var controller: NBBOverlayController
    @State private var advancedExpanded = false
    @State private var isResetConfirming = false

    public init(controller: NBBOverlayController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if controller.isEnabled, !controller.isReachable {
                STRequirementStrip(
                    kind: .warning,
                    message: controller.readsWindow
                        ? "sTools can\u{2019}t read this Ninjabrain Bot\u{2019}s window. It needs Accessibility, and the window must be open."
                        : "Ninjabrain Bot isn't reachable at localhost:52533 — enable its API under Settings ▸ Advanced in Ninjabrain Bot.")
            }
            if controller.copies.showsCopies {
                NBBCopiesList(monitor: controller.copies)
            }
            if let version = controller.nbbVersion {
                Text("Ninjabrain Bot \(version)").stStyle(.caption).foregroundStyle(STColor.inkSecondary)
            }

            STPlate {
                NBBPagePreview(controller: controller)
            }

            VStack(alignment: .leading, spacing: 0) {
                STSettingsRow("Move and resize by dragging") {
                    STSwitch(isOn: $controller.settings.placementModeEnabled, label: "Move and resize by dragging")
                }
                if controller.settings.placementModeEnabled {
                    STSettingsRow("Snap to edges and center", showsRule: false) {
                        STSwitch(isOn: $controller.settings.snappingEnabled, label: "Snap to edges and center")
                    }
                    Text("Turn the tool on, then drag the overlay on screen to move it, or its corner handle to resize. The fields below still work the same way, and update live as you drag.")
                        .stStyle(.caption).foregroundStyle(STColor.inkSecondary).padding(.bottom, 10)
                }
                STSettingsRow("Position") {
                    HStack(spacing: 8) {
                        STNumberField(value: offsetXBinding, label: "Horizontal offset", axis: "X")
                        STNumberField(value: offsetYBinding, label: "Vertical offset", axis: "Y")
                    }
                }
                STSettingsRow("Width") {
                    STSlider(value: widthBinding, in: Double(NBBOverlaySettings.widthRange.lowerBound)...Double(NBBOverlaySettings.widthRange.upperBound), label: "Width", valueText: { "\(Int($0)) px" })
                }
                STSettingsRow("Aspect ratio", combinesForAccessibility: false) {
                    STSegmented(selection: aspectRatioPresetBinding, options: NBBAspectRatioPreset.allCases.map { STSegmentedOption($0, $0.title) })
                }
                if aspectRatioPresetBinding.wrappedValue == .custom {
                    STSettingsRow("Custom ratio", showsRule: false) {
                        STSlider(value: aspectRatioBinding, in: NBBOverlaySettings.aspectRatioRange, step: 0.05, label: "Custom ratio", valueText: { String(format: "%.2f", $0) })
                    }
                }
                STSettingsRow("Plate opacity") {
                    STSlider(value: plateOpacityBinding, in: Double(NBBOverlaySettings.plateOpacityRange.lowerBound)...Double(NBBOverlaySettings.plateOpacityRange.upperBound), label: "Plate opacity", valueText: { "\(Int($0))%" })
                }
                STSettingsRow("Show when there is data") {
                    STSwitch(isOn: $controller.settings.requiresData, label: "Show when there is data")
                }
                STSettingsRow("Show only while Minecraft is focused") {
                    STSwitch(isOn: $controller.settings.requiresMinecraftFocus, label: "Show only while Minecraft is focused")
                }
                STSettingsRow("Predictions") { STSwitch(isOn: $controller.settings.showsPredictions, label: "Predictions") }
                STSettingsRow("Eye throws") { STSwitch(isOn: $controller.settings.showsEyeThrows, label: "Eye throws") }
                STSettingsRow("Boat indicator") { STSwitch(isOn: $controller.settings.showsBoatState, label: "Boat indicator") }
                STSettingsRow("Color the plate by boat") {
                    STSwitch(isOn: $controller.settings.tintsPlateByBoat, label: "Color the plate by boat")
                }
                STSettingsRow("Information messages", showsRule: false) {
                    STSwitch(isOn: $controller.settings.showsInformationMessages, label: "Information messages")
                }
            }

            STAdvancedDisclosure(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    STSettingsRow("Location column") { STSwitch(isOn: $controller.settings.showsLocationColumn, label: "Location column") }
                    STSettingsRow("Nether coordinates in the Nether") {
                        STSwitch(isOn: $controller.settings.showsNetherCoordinatesInNether, label: "Nether coordinates in the Nether")
                    }
                    STSettingsRow("Location shown as", combinesForAccessibility: false) {
                        STSegmented(
                            selection: $controller.settings.locationDisplay,
                            options: NBBLocationDisplay.allCases.map { STSegmentedOption($0, $0.title) })
                    }
                    STSettingsRow("Certainty column") { STSwitch(isOn: $controller.settings.showsCertaintyColumn, label: "Certainty column") }
                    STSettingsRow("Distance column") { STSwitch(isOn: $controller.settings.showsDistanceColumn, label: "Distance column") }
                    STSettingsRow("Angle column") { STSwitch(isOn: $controller.settings.showsAngleColumn, label: "Angle column") }
                    STSettingsRow("Angle change column") {
                        STSwitch(isOn: $controller.settings.showsAngleChangeColumn, label: "Angle change column")
                    }
                    STSettingsRow("Show the gray boat") {
                        STSwitch(isOn: $controller.settings.showsGrayBoat, label: "Show the gray boat")
                    }
                    STSettingsRow("Prediction rows") {
                        STSlider(value: maxRowsBinding, in: Double(NBBOverlaySettings.maxPredictionRowsRange.lowerBound)...Double(NBBOverlaySettings.maxPredictionRowsRange.upperBound), label: "Prediction rows", valueText: { "\(Int($0))" })
                    }
                    STSettingsRow("Fade on reset") {
                        STSwitch(isOn: $controller.settings.fadeOnResetEnabled, label: "Fade on reset")
                    }
                    if controller.settings.fadeOnResetEnabled {
                        STSettingsRow("Fade duration") {
                            STSlider(value: $controller.settings.fadeSeconds, in: NBBOverlaySettings.fadeSecondsRange, step: 0.05, label: "Fade duration", valueText: { String(format: "%.2f s", $0) })
                        }
                    }
                    STSettingsRow("Reset", showsRule: false) {
                        Button("Reset to default\u{2026}") { isResetConfirming = true }
                            .buttonStyle(STButtonStyle(.secondary))
                    }
                }
            }
        }
        .confirmationDialog(
            "Reset NBB Overlay to default?", isPresented: $isResetConfirming, titleVisibility: .visible,
            actions: {
                Button("Reset to Default", role: .destructive) { controller.resetToDefault() }
                Button("Cancel", role: .cancel) {}
            },
            message: { Text("This sets every NBB Overlay setting back to its default.") })
    }

    private var offsetXBinding: Binding<Int> {
        Binding(get: { controller.settings.offsetX }, set: { controller.settings.offsetX = $0 })
    }

    private var offsetYBinding: Binding<Int> {
        Binding(get: { controller.settings.offsetY }, set: { controller.settings.offsetY = $0 })
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.width) }, set: { controller.settings.width = Int($0.rounded()) })
    }

    private var aspectRatioBinding: Binding<Double> {
        Binding(get: { controller.settings.aspectRatio }, set: { controller.settings.aspectRatio = $0 })
    }

    /// Reads back as whichever preset the current ratio matches (or `.custom`); picking a fixed
    /// preset applies its ratio immediately, picking `.custom` just reveals the free-form slider.
    private var aspectRatioPresetBinding: Binding<NBBAspectRatioPreset> {
        Binding(
            get: { NBBAspectRatioPreset.matching(controller.settings.aspectRatio) },
            set: { preset in
                if let ratio = preset.ratio { controller.settings.aspectRatio = ratio }
            })
    }

    private var plateOpacityBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.plateOpacityPercent) }, set: { controller.settings.plateOpacityPercent = Int($0.rounded()) })
    }

    private var maxRowsBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.maxPredictionRows) }, set: { controller.settings.maxPredictionRows = Int($0.rounded()) })
    }
}

/// A small labeled integer field, for the position X/Y typed input (spec 5.1.5 "or type X/Y").
private struct STNumberField: View {
    @Binding var value: Int
    let label: String
    /// The small-caps letter in front of the field, so it's clear which box is which.
    let axis: String
    @State private var text = ""
    @Environment(\.stTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(axis)
                .stStyle(.label)
                .foregroundStyle(theme.inkSecondary)
                .accessibilityHidden(true)
            field
        }
    }

    private var field: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .font(STFont.figures(13 * theme.textScale))
            .stFieldLineHeight(13 * theme.textScale, weight: .medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 64)
            .background(STColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(theme.stroke, lineWidth: 1))
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(label)
            .onAppear { text = String(value) }
            .onChange(of: value) { _, newValue in text = String(newValue) }
            .onSubmit { commit() }
            .onChange(of: text) { _, newValue in
                if let parsed = Int(newValue) { value = parsed }
            }
    }

    private func commit() {
        if let parsed = Int(text) { value = parsed } else { text = String(value) }
    }
}

/// The page's preview (spec 3.5: every tool page has one): the overlay as it shows over the game with Ninjabrain
/// Bot's live result, shrunk to fit if it's wider than the plate, or a line saying where it will appear.
private struct NBBPagePreview: View {
    let controller: NBBOverlayController
    @Environment(\.stTheme) private var theme

    private var settings: NBBOverlaySettings {
        var settings = controller.settings
        settings.placementModeEnabled = false
        return settings
    }

    private var overlaySize: CGSize {
        CGSize(width: CGFloat(settings.width), height: CGFloat(settings.width) / settings.aspectRatio)
    }

    var body: some View {
        let content = controller.previewContent
        let messages = controller.previewMessages
        let boat = controller.previewBoat
        if content == .hidden && messages.isEmpty && !NBBOverlayLayout.boatCountsAsData(boat, settings: settings) {
            Text("Ninjabrain Bot\u{2019}s result appears here as it will over the game, once it has one.")
                .stStyle(.caption)
                .foregroundStyle(theme.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 96)
                .padding(.horizontal, 16)
        } else {
            GeometryReader { proxy in
                let scale = min(1, (proxy.size.width - 20) / overlaySize.width)
                NBBOverlayView(content: content, messages: messages, settings: settings, boat: boat)
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: overlaySize.height * min(1, 600 / overlaySize.width) + 20)
        }
    }
}

/// The open Ninjabrain Bots, with the one the overlay reads marked. Pick another with Read This One; every copy stays
/// open. A copy holding the API is read over it, any other from its window (predictions, eye throws and notes; no boat).
private struct NBBCopiesList: View {
    let monitor: NBBCopiesMonitor
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(monitor.copies.count > 1 ? "Ninjabrain Bots open" : "Ninjabrain Bot")
                .stStyle(.label).foregroundStyle(theme.inkTertiary).padding(.bottom, 6)
            ForEach(Array(monitor.copies.enumerated()), id: \.element.pid) { index, copy in
                HStack(spacing: 10) {
                    Circle()
                        .fill(monitor.isRead(copy) ? STColor.gold : Color.clear)
                        .overlay(Circle().strokeBorder(monitor.isRead(copy) ? STColor.gold : theme.stroke, lineWidth: 1))
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(NBBCopiesMonitor.description(of: copy))
                        .stStyle(.body)
                        .foregroundStyle(STColor.ink)
                    Spacer(minLength: 8)
                    if monitor.isRead(copy) {
                        Text("Reading").stStyle(.caption).foregroundStyle(STColor.gold)
                    } else {
                        Button("Read This One") { monitor.choice = .copy(copy.pid) }
                            .buttonStyle(STButtonStyle(.secondary))
                    }
                    if monitor.copies.count > 1 {
                        Button("Quit") { monitor.quit(copy) }
                            .buttonStyle(STButtonStyle(.quiet))
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Ninjabrain Bot \(index + 1)\(monitor.isRead(copy) ? ", read by the overlay" : "")")
            }
            Text(caption)
                .stStyle(.caption).foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if monitor.choice != .automatic {
                Button("Follow the Newest Copy") { monitor.choice = .automatic }
                    .buttonStyle(STButtonStyle(.quiet))
                    .padding(.top, 4)
            }
        }
    }

    private var caption: String {
        let api = "Only one Ninjabrain Bot can share its data over the API; sTools reads any other from its window: predictions, eye throws and notes, without the boat."
        return monitor.choice == .automatic ? "The overlay follows the newest copy. " + api : api
    }
}
