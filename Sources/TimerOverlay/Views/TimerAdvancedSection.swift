import STDesign
import STPlatform
import SwiftUI

/// The rows inside the Timer page's **Advanced ▸** (spec 5.6.7): every setting the main section doesn't show, then
/// **Reset to default…** with the confirmation the other tools use. Turning "Show in recordings" off asks
/// `confirmHidingFromRecordings` first, which warns that hiding an aid can turn a rejected run into a ban (A.12.3);
/// tests replace it, so no test opens an alert. The words are placeholder wording for M9.
struct TimerAdvancedSection: View {
    @Bindable var controller: TimerOverlayController
    let confirmHidingFromRecordings: @MainActor () -> Bool
    @State private var isResetConfirming = false
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appearanceRows
            timeRows
            motionRows
            keyRows
            alarmRows
            whereRows
            presetRows
            STSettingsRow("Reset", showsRule: false) {
                Button("Reset to default\u{2026}") { isResetConfirming = true }
                    .buttonStyle(STButtonStyle(.secondary))
            }
        }
        .stAnimation(STMotion.quick, value: revealed)
        .confirmationDialog(
            "Reset Timer Overlay to default?", isPresented: $isResetConfirming, titleVisibility: .visible,
            actions: {
                Button("Reset to Default", role: .destructive) { controller.resetToDefault() }
                Button("Cancel", role: .cancel) {}
            },
            message: { Text("This sets every Timer Overlay setting back to its default.") })
    }

    private var settings: TimerOverlaySettings { controller.settings }

    /// The rows that come and go with another row's choice, so they appear and leave through `STMotion`.
    private var revealed: [Bool] {
        [settings.showsLabel, settings.nearZero != .off, settings.nearZero == .goldThenDanger, settings.atZero == .word,
         settings.beforeZero == .chime, settings.displayChoice == .specific, settings.showsRuleGuides]
    }

    // MARK: - The overlay's look

    @ViewBuilder private var appearanceRows: some View {
        let own = lookColors
        STSettingsRow("Font") { TimerFontMenu(family: $controller.settings.fontFamily) }
        STSettingsRow("Plate color") { STColorWell(hex: hex(\.plateColorHex, own: own.plateColor), label: "Plate color") }
        STSettingsRow("Plate opacity") {
            STSlider(value: plateOpacityBinding, in: Double(TimerOverlaySettings.plateOpacityRange.lowerBound)...Double(TimerOverlaySettings.plateOpacityRange.upperBound),
                     label: "Plate opacity", valueText: { "\(Int($0))%" })
        }
        STSettingsRow("Edge color") { STColorWell(hex: hex(\.edgeColorHex, own: own.edgeColor), label: "Edge color") }
        STSettingsRow("Edge width") {
            STSlider(value: edgeWidthBinding, in: TimerOverlaySettings.edgeWidthRange, step: 0.5, label: "Edge width",
                     valueText: { "\(Self.points($0)) pt" })
        }
        STSettingsRow("Corner radius") {
            STSlider(value: cornerRadiusBinding, in: TimerOverlaySettings.cornerRadiusRange, label: "Corner radius",
                     valueText: { "\(Int($0)) pt" })
        }
        STSettingsRow("Digit color") { STColorWell(hex: hex(\.digitColorHex, own: own.digitColor), label: "Digit color") }
        STSettingsRow("Time\u{2019}s-up plate color") {
            STColorWell(hex: hex(\.timesUpPlateColorHex, own: own.timesUpPlateColor), label: "Time\u{2019}s-up plate color")
        }
        STSettingsRow("Time\u{2019}s-up digit color") {
            STColorWell(hex: hex(\.timesUpDigitColorHex, own: own.timesUpDigitColor), label: "Time\u{2019}s-up digit color")
        }
        STSettingsRow("Colors") {
            Button("Use the look\u{2019}s own") { useLookColors() }
                .buttonStyle(STButtonStyle(.secondary))
                .disabled(!hasColorOverrides)
        }
        STSettingsRow("Label") { STSwitch(isOn: $controller.settings.showsLabel, label: "Label") }
        if settings.showsLabel {
            STSettingsRow("Label text") {
                STTextField("Label text", text: $controller.settings.labelText).frame(width: 160)
            }
            .transition(.opacity)
        }
        STChoiceRow("Progress") {
            STSegmented(selection: $controller.settings.progress, options: [.init(.off, "None"), .init(.bar, "Bar"), .init(.ring, "Ring")])
        }
        STSettingsRow("Color near zero") {
            TimerChoiceMenu(selection: $controller.settings.nearZero, options: [
                .init(.off, "Off"), .init(.gold, "Gold"), .init(.goldThenDanger, "Gold, then red"),
            ], label: "Color near zero")
        }
        if settings.nearZero != .off {
            STSettingsRow("Gold from") {
                TimerDurationField(seconds: $controller.settings.nearZeroGoldSeconds, label: "Gold from, time left")
            }
            .transition(.opacity)
        }
        if settings.nearZero == .goldThenDanger {
            STSettingsRow("Red from") {
                TimerDurationField(seconds: $controller.settings.nearZeroDangerSeconds, label: "Red from, time left")
            }
            .transition(.opacity)
        }
    }

    // MARK: - The time

    @ViewBuilder private var timeRows: some View {
        STChoiceRow("Time format") {
            STSegmented(selection: $controller.settings.timeFormat, options: [
                .init(.minutesAndSeconds, "MM:SS"), .init(.shortMinutes, "M:SS"), .init(.secondsOnly, "Seconds"),
            ])
        }
        STSettingsRow("Tenths in the last 10 s") {
            STSwitch(isOn: $controller.settings.showsTenths, label: "Tenths in the last 10 s")
        }
        STChoiceRow("At zero, show") {
            STSegmented(selection: $controller.settings.atZero, options: [
                .init(.holdZero, "00:00"), .init(.word, "A word"), .init(.overtime, "Overtime"),
            ])
        }
        if settings.atZero == .word {
            STSettingsRow("Word") {
                STTextField("Word at zero", text: $controller.settings.atZeroWord).frame(width: 160)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Motion

    @ViewBuilder private var motionRows: some View {
        STChoiceRow("Pop-up motion") {
            STSegmented(selection: $controller.settings.popUpMotion, options: [
                .init(.springPop, "Pop"), .init(.fade, "Fade"), .init(.slide, "Slide"), .init(.instant, "None"),
            ])
        }
        STSettingsRow("While ringing") {
            TimerChoiceMenu(selection: $controller.settings.whileRinging, options: [
                .init(.pulsePerRing, "One pulse per ring"), .init(.timesUpLookOnly, "Time\u{2019}s-up look only"),
                .init(.quickFlashes, "Quick flashes"),
            ], label: "While ringing")
        }
        STSettingsRow("Leave") {
            TimerChoiceMenu(selection: $controller.settings.leave, options: [
                .init(.afterLastRing, "After the last ring"), .init(.afterZero, "A set time after zero"),
            ], label: "Leave")
        }
        if settings.leave == .afterLastRing {
            STSettingsRow("Stay after the last ring") {
                STSlider(value: $controller.settings.leaveAfterLastRingSeconds, in: TimerOverlaySettings.leaveAfterLastRingRange,
                         step: 0.5, label: "Stay after the last ring", valueText: { "\(Self.points($0)) s" })
            }
        } else {
            STSettingsRow("Leave after zero") {
                STSlider(value: $controller.settings.leaveAfterZeroSeconds, in: TimerOverlaySettings.leaveAfterZeroRange,
                         step: 0.5, label: "Leave after zero", valueText: { "\(Self.points($0)) s" })
            }
        }
        STSettingsRow("While paused") {
            TimerChoiceMenu(selection: $controller.settings.whilePaused, options: [
                .init(.hideAfterDelay, "Hide after 3 s"), .init(.stayUp, "Stay up"), .init(.hideAtOnce, "Hide at once"),
            ], label: "While paused")
        }
    }

    // MARK: - The key

    @ViewBuilder private var keyRows: some View {
        STSettingsRow("A press while counting") {
            TimerChoiceMenu(selection: $controller.settings.pressWhileCounting, options: [
                .init(.restart, "Restarts"), .init(.cancel, "Cancels"), .init(.pauseOrResume, "Pauses or resumes"),
                .init(.ignore, "Is ignored"),
            ], label: "A press while counting")
        }
        STSettingsRow("A press while ringing") {
            TimerChoiceMenu(selection: $controller.settings.pressWhileRinging, options: [
                .init(.newCountdown, "Starts a new countdown"), .init(.silenceAndHide, "Silences and hides"),
                .init(.ignore, "Is ignored"),
            ], label: "A press while ringing or lingering")
        }
        STChoiceRow("Cancel gesture", showsRule: false) {
            STSegmented(selection: $controller.settings.cancelGesture, options: [
                .init(.doublePress, "Double press"), .init(.hold, "Hold"), .init(.off, "None"),
            ])
        }
        STNoteLine(Self.cancelGestureNote(for: settings.cancelGesture))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
    }

    /// What the cancel gesture does, under its row (spec 5.6.2): either gesture switches Timer Overlay off, and the
    /// next press switches it back on. With None no gesture does, so the line says the key never will and points to the
    /// switch. Wording from ducky's M9 review (B138, B139); None's is B140b, set at ducky's request because B140's
    /// ("Only the double click gesture will turn off the Timer Overlay.") isn't true there (revision 42).
    static func cancelGestureNote(for gesture: TimerOverlaySettings.CancelGesture) -> String {
        let back = "Press again to turn it on and start."
        return switch gesture {
        case .doublePress:
            "Press twice within \(points(PressPolicy.doublePressWindow)) s to switch Timer Overlay off. \(back)"
        case .hold:
            "Hold the key for \(points(PressPolicy.holdDuration)) s to switch Timer Overlay off. \(back)"
        case .off:
            "The key will never turn off the Timer Overlay. Use its switch."
        }
    }

    // MARK: - The alarm

    @ViewBuilder private var alarmRows: some View {
        STSettingsRow("Before zero") {
            TimerChoiceMenu(selection: $controller.settings.beforeZero, options: [
                .init(.nothing, "Nothing"), .init(.chime, "A chime"), .init(.ticks, "Tick in the last 5 seconds"),
            ], label: "Before zero")
        }
        if settings.beforeZero == .chime {
            STSettingsRow("Chime at") {
                TimerDurationField(seconds: $controller.settings.chimeAtSeconds, label: "Chime at, time left")
            }
            .transition(.opacity)
        }
        STSettingsRow("Alarm in sTools recordings") {
            STSwitch(isOn: $controller.settings.alarmInRecordings, label: "Alarm in sTools recordings")
        }
        STSettingsRow("Show in recordings") {
            STSwitch(isOn: showsInRecordingsBinding, label: "Show in recordings")
        }
    }

    // MARK: - Where it shows

    @ViewBuilder private var whereRows: some View {
        STSettingsRow("Visibility") {
            TimerChoiceMenu(selection: $controller.settings.visibleOnlyWhileMinecraftFocused, options: [
                .init(false, "Whenever it\u{2019}s up"), .init(true, "Only while Minecraft is focused"),
            ], label: "Visibility")
        }
        STSettingsRow("Pause while Minecraft isn\u{2019}t focused") {
            STSwitch(isOn: $controller.settings.pausesWhileMinecraftNotFocused, label: "Pause while Minecraft isn\u{2019}t focused")
        }
        STChoiceRow("Display") {
            STSegmented(selection: $controller.settings.displayChoice, options: [
                .init(.followMinecraft, "Follow Minecraft"), .init(.specific, "A specific display"),
            ])
        }
        if settings.displayChoice == .specific {
            STSettingsRow("Which display") {
                TimerChoiceMenu(selection: specificDisplayBinding, options: displayOptions, label: "Which display")
            }
            .transition(.opacity)
        }
        STSettingsRow("Snapping") {
            STSwitch(isOn: $controller.settings.snappingEnabled, label: "Snapping")
        }
        STSettingsRow("Rule guides while placing") {
            STSwitch(isOn: $controller.settings.showsRuleGuides, label: "Rule guides while placing")
        }
        if settings.showsRuleGuides {
            STSettingsRow("GUI scale") {
                TimerChoiceMenu(selection: $controller.settings.guiScale, options: Self.guiScaleOptions, label: "GUI scale")
            }
            .transition(.opacity)
            STSettingsRow("SpeedRunIGT\u{2019}s timer") {
                TimerChoiceMenu(selection: $controller.settings.speedRunIGTCorner, options: [
                    .init(.topLeft, "Top left"), .init(.topRight, "Top right"),
                    .init(.bottomLeft, "Bottom left"), .init(.bottomRight, "Bottom right"),
                ], label: "SpeedRunIGT\u{2019}s timer corner")
            }
            .transition(.opacity)
        }
        STSettingsRow("Countdown on the Dock icon") {
            STSwitch(isOn: $controller.settings.showsDockCountdown, label: "Countdown on the Dock icon")
        }
    }

    // MARK: - Presets

    @ViewBuilder private var presetRows: some View {
        STSettingsRow("Presets") {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(settings.presets.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        STTextField("Preset name", text: presetTitleBinding(index)).frame(width: 96)
                        TimerDurationField(seconds: presetSecondsBinding(index), label: "Preset length", width: 104)
                        Button { removePreset(index) } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 14 * theme.textScale))
                                .foregroundStyle(theme.inkSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove preset")
                    }
                }
                Button("Add Preset") { addPreset() }
                    .buttonStyle(STButtonStyle(.quiet))
            }
        }
    }

    // MARK: - Bindings

    /// The look's own colors, as drawn now: what a color well shows until the owner picks one.
    private struct LookColors {
        var plateColor: String
        var edgeColor: String
        var digitColor: String
        var timesUpPlateColor: String
        var timesUpDigitColor: String
    }

    private var lookColors: LookColors {
        var own = settings
        own.plateColorHex = nil
        own.edgeColorHex = nil
        own.digitColorHex = nil
        own.timesUpPlateColorHex = nil
        own.timesUpDigitColorHex = nil
        let counting = TimerLook(settings: own, state: .counting, increaseContrast: theme.increaseContrast)
        let timesUp = TimerLook(settings: own, state: .timesUp, increaseContrast: theme.increaseContrast)
        return LookColors(
            plateColor: counting.plate?.colorHex ?? STPalette.background, edgeColor: counting.plate?.edgeHex ?? STPalette.rule,
            digitColor: counting.digitHex, timesUpPlateColor: timesUp.plate?.colorHex ?? STPalette.gold,
            timesUpDigitColor: timesUp.digitHex)
    }

    private func hex(_ path: WritableKeyPath<TimerOverlaySettings, String?>, own: String) -> Binding<String> {
        Binding(get: { controller.settings[keyPath: path] ?? own }, set: { controller.settings[keyPath: path] = $0 })
    }

    private var hasColorOverrides: Bool {
        settings.plateColorHex != nil || settings.plateOpacityPercent != nil || settings.edgeColorHex != nil
            || settings.edgeWidth != nil || settings.cornerRadius != nil || settings.digitColorHex != nil
            || settings.timesUpPlateColorHex != nil || settings.timesUpDigitColorHex != nil
    }

    private func useLookColors() {
        var settings = controller.settings
        settings.plateColorHex = nil
        settings.plateOpacityPercent = nil
        settings.edgeColorHex = nil
        settings.edgeWidth = nil
        settings.cornerRadius = nil
        settings.digitColorHex = nil
        settings.timesUpPlateColorHex = nil
        settings.timesUpDigitColorHex = nil
        controller.settings = settings
    }

    private var plateOpacityBinding: Binding<Double> {
        Binding(get: { Double(controller.settings.plateOpacityPercent ?? 85) },
                set: { controller.settings.plateOpacityPercent = Int($0.rounded()) })
    }

    private var edgeWidthBinding: Binding<Double> {
        Binding(get: { controller.settings.edgeWidth ?? 1 }, set: { controller.settings.edgeWidth = $0 })
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(get: { controller.settings.cornerRadius ?? 12 }, set: { controller.settings.cornerRadius = $0 })
    }

    /// Turning it on applies at once; turning it off asks first (A.12.3).
    private var showsInRecordingsBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.showsInRecordings },
            set: { controller.settings.showsInRecordings = Self.showsInRecordings(after: $0, confirm: confirmHidingFromRecordings) })
    }

    /// "Show in recordings" after the switch is set to `isOn`: on at once, off only when the owner confirms the
    /// warning, which is asked only then.
    static func showsInRecordings(after isOn: Bool, confirm: @MainActor () -> Bool) -> Bool {
        isOn || !confirm()
    }

    /// The display picked, or the main display while none is.
    private var specificDisplayBinding: Binding<UInt32> {
        Binding(
            get: { controller.settings.specificDisplayID ?? controller.services.displays.main?.id ?? 0 },
            set: { controller.settings.specificDisplayID = $0 })
    }

    private var displayOptions: [STSegmentedOption<UInt32>] {
        var options = controller.services.displays.displays.map { STSegmentedOption($0.id, $0.name) }
        if let id = settings.specificDisplayID, !options.contains(where: { $0.value == id }) {
            options.append(STSegmentedOption(id, "A display that isn\u{2019}t connected"))
        }
        return options
    }

    static let guiScaleOptions: [STSegmentedOption<TimerOverlaySettings.GUIScale>] =
        [STSegmentedOption(.auto, "Auto")] + (1...8).map { STSegmentedOption(.fixed($0), "\($0)") }

    private func presetTitleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { controller.settings.presets.indices.contains(index) ? controller.settings.presets[index].title : "" },
            set: { if controller.settings.presets.indices.contains(index) { controller.settings.presets[index].title = $0 } })
    }

    private func presetSecondsBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { controller.settings.presets.indices.contains(index) ? controller.settings.presets[index].seconds : 1 },
            set: { if controller.settings.presets.indices.contains(index) { controller.settings.presets[index].seconds = $0 } })
    }

    private func removePreset(_ index: Int) {
        guard controller.settings.presets.indices.contains(index) else { return }
        controller.settings.presets.remove(at: index)
    }

    /// A new chip for the duration set now.
    private func addPreset() {
        let seconds = controller.settings.durationSeconds
        controller.settings.presets.append(
            TimerOverlaySettings.Preset(title: ClockFormat.string(seconds: seconds, format: .shortMinutes), seconds: seconds))
    }

    /// "1", "1.5": a half-step value without a trailing ".0".
    static func points(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

/// A pop-up menu that picks one of `options`, in the app's type (`STMenuLabel`), with a check beside the current one.
struct TimerChoiceMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [STSegmentedOption<Value>]
    let label: String

    var body: some View {
        let title = options.first { $0.value == selection }?.title ?? ""
        Menu {
            ForEach(options) { option in
                Button { selection = option.value } label: {
                    if option.value == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            STMenuLabel(title)
        }
        .stMenuStyle()
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}

/// The digits' font: the four offered by name, then every installed family in a submenu (spec 5.6.7). A family
/// that isn't installed falls back to Source Serif 4 when drawn, and the menu says so.
struct TimerFontMenu: View {
    @Binding var family: String

    var body: some View {
        let title = TimerFont.isAvailable(family) ? family : "\(family) (missing)"
        Menu {
            ForEach(TimerFont.offeredFamilies, id: \.self) { item($0) }
            Divider()
            Menu("Other Fonts") {
                ForEach(Self.otherFamilies, id: \.self) { item($0) }
            }
        } label: {
            STMenuLabel(title)
        }
        .stMenuStyle()
        .accessibilityLabel("Font")
        .accessibilityValue(title)
    }

    /// Every other installed family, listed once per launch: the menu is rebuilt whenever a setting changes, and
    /// asking the font manager each time would cost more than the list is worth.
    static let otherFamilies = TimerFont.installedFamilies().filter { !TimerFont.offeredFamilies.contains($0) }

    private func item(_ name: String) -> some View {
        Button { family = name } label: {
            if name == family { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}
