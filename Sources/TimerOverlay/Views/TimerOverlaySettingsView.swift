import AppKit
import STDesign
import SwiftUI
import UniformTypeIdentifiers

/// What the Timer page asks of AppKit: a sound file to add as the alarm, and a yes before the overlay is hidden from
/// recordings. Tests pass their own, so no test opens a panel or an alert.
public struct TimerPageActions {
    /// Asks for one audio file; nil when the owner cancels.
    public var chooseSoundFile: @MainActor () -> URL?
    /// Warns that hiding an aid from the run's video can turn a rejected run into a ban (A.12.3); true to hide it.
    public var confirmHidingFromRecordings: @MainActor () -> Bool

    public init(chooseSoundFile: @escaping @MainActor () -> URL?,
                confirmHidingFromRecordings: @escaping @MainActor () -> Bool) {
        self.chooseSoundFile = chooseSoundFile
        self.confirmHidingFromRecordings = confirmHidingFromRecordings
    }

    /// The open panel and the warning, as the app shows them.
    @MainActor
    public static var live: TimerPageActions {
        TimerPageActions(
            chooseSoundFile: {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.prompt = "Add"
                panel.message = "Choose an alarm sound."
                return panel.runModal() == .OK ? panel.url : nil
            },
            confirmHidingFromRecordings: {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Hide Timer Overlay from recordings?"
                alert.informativeText = "Runs must show every aid you use."
                alert.addButton(withTitle: "Keep in Recordings")
                alert.addButton(withTitle: "Hide from Recordings")
                return alert.runModal() == .alertSecondButtonReturn
            })
    }
}

/// Everything below the page header for Timer Overlay (spec 5.6.3): the preview plate with the live time, Start,
/// Pause / Resume, Cancel and Test, Duration, the everyday
/// settings, then an Advanced section with every other row of spec 5.6.7. The Start-timer key is set on the page's
/// Hotkey row above, as every tool page's is (spec 6.1).
public struct TimerOverlaySettingsView: View {
    @Bindable private var controller: TimerOverlayController
    private let actions: TimerPageActions?
    @State private var advancedExpanded: Bool

    /// - Parameter actions: the open panel and the recordings warning; nil uses the live ones.
    public init(controller: TimerOverlayController, actions: TimerPageActions? = nil) {
        self.init(controller: controller, actions: actions, showsAdvanced: false)
    }

    /// Test hook: the same page, with Advanced open or closed from the start.
    init(controller: TimerOverlayController, actions: TimerPageActions?, showsAdvanced: Bool) {
        self.controller = controller
        self.actions = actions
        _advancedExpanded = State(initialValue: showsAdvanced)
    }

    public var body: some View {
        let actions = actions ?? .live
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                TimerPreviewPlate(controller: controller)
                TimerRunControls(controller: controller)
            }

            VStack(alignment: .leading, spacing: 0) {
                DurationPicker(settings: $controller.settings)
                STChoiceRow("Look") {
                    STSegmented(selection: $controller.settings.look, options: [
                        .init(.plate, "sTools plate"), .init(.digitsOnly, "Digits only"), .init(.compactPill, "Compact pill"),
                    ])
                }
                STSettingsRow("Digit size") {
                    STSlider(value: digitSizeBinding,
                             in: Double(TimerOverlaySettings.digitSizeRange.lowerBound)...Double(TimerOverlaySettings.digitSizeRange.upperBound),
                             label: "Digit size", valueText: { "\(Int($0)) pt" })
                }
                STSettingsRow("Move by dragging") {
                    STSwitch(isOn: placementBinding, label: "Move by dragging")
                        .disabled(!controller.isAvailable)
                }
                if controller.isPlacing {
                    Text("Drag the timer to move it.")
                        .stStyle(.caption)
                        .foregroundStyle(STColor.inkSecondary)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
                STSettingsRow("Position") {
                    HStack(spacing: 8) {
                        TimerNumberField(value: $controller.settings.offsetX, label: "Horizontal offset", axis: "X")
                        TimerNumberField(value: $controller.settings.offsetY, label: "Vertical offset", axis: "Y")
                    }
                }
                AlarmSoundPicker(controller: controller, chooseSoundFile: actions.chooseSoundFile)
                STSettingsRow("Volume") {
                    STSlider(value: volumeBinding, in: 0...100, label: "Volume", valueText: { "\(Int($0))%" })
                }
                STSettingsRow("Rings", showsRule: false) {
                    STSlider(value: ringsBinding,
                             in: Double(TimerOverlaySettings.ringsRange.lowerBound)...Double(TimerOverlaySettings.ringsRange.upperBound),
                             label: "Rings", valueText: { "\(Int($0))" })
                }
            }
            .stAnimation(STMotion.quick, value: controller.isPlacing)

            STAdvancedDisclosure(isExpanded: $advancedExpanded) {
                TimerAdvancedSection(controller: controller, confirmHidingFromRecordings: actions.confirmHidingFromRecordings)
            }
        }
    }

    private var digitSizeBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.digitSize) }, set: { controller.settings.digitSize = Int($0.rounded()) })
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { (controller.settings.volume * 100).rounded() }, set: { controller.settings.volume = $0.rounded() / 100 })
    }

    private var ringsBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.rings) }, set: { controller.settings.rings = Int($0.rounded()) })
    }

    /// On switches the tool on first, as Start does (plan decision 13); the switch shows whether placement is on.
    private var placementBinding: Binding<Bool> {
        Binding(get: { controller.isPlacing }, set: { controller.setPlacementMode($0) })
    }
}

/// A small labeled whole-number field for the typed X/Y position (spec 5.6.5 "or type X/Y"), as on the NBB page.
struct TimerNumberField: View {
    @Binding var value: Int
    let label: String
    /// The small-caps letter in front of the field, so it's clear which box is which.
    let axis: String
    @State private var text: String
    @Environment(\.stTheme) private var theme

    init(value: Binding<Int>, label: String, axis: String) {
        _value = value
        self.label = label
        self.axis = axis
        _text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(axis)
                .stStyle(.label)
                .foregroundStyle(theme.inkSecondary)
                .accessibilityHidden(true)
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
                .onChange(of: value) { _, newValue in
                    if Int(text) != newValue { text = String(newValue) }
                }
                .onChange(of: text) { _, newValue in
                    if let parsed = Int(newValue), parsed != value { value = parsed }
                }
                .onSubmit { text = String(value) }
        }
    }
}
