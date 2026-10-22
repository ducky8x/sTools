import STDesign
import SwiftUI

/// The page's Duration (spec 5.6.3, Timer round C1): the preset chips plus **Custom**, which shows an `H:MM:SS` field
/// for any length from 1 s to 99:59:59. It only writes `durationSeconds`, so a change applies to the next run, never
/// to one in progress.
struct DurationPicker: View {
    @Binding var settings: TimerOverlaySettings
    /// Custom was picked while the duration still matches a preset, so the field shows anyway.
    @State private var customPicked = false

    /// One chip: a preset, by its place in the list, or Custom.
    enum Choice: Hashable {
        case preset(Int)
        case custom
    }

    /// The chip that reads as picked: Custom once it was picked or when no preset matches the duration, otherwise
    /// the first preset with the duration's length.
    static func choice(duration: Int, presets: [TimerOverlaySettings.Preset], customPicked: Bool) -> Choice {
        guard !customPicked, let index = presets.firstIndex(where: { $0.seconds == duration }) else { return .custom }
        return .preset(index)
    }

    var body: some View {
        let choice = Self.choice(duration: settings.durationSeconds, presets: settings.presets, customPicked: customPicked)
        VStack(alignment: .leading, spacing: 0) {
            STSettingsRow("Duration", showsRule: choice != .custom) {
                STChips(selection: selection(choice), options: options, label: "Duration")
                    .frame(maxWidth: 340, alignment: .trailing)
            }
            if choice == .custom {
                STSettingsRow("Custom duration") {
                    TimerDurationField(seconds: $settings.durationSeconds, label: "Custom duration")
                }
                .transition(.opacity)
            }
        }
        .stAnimation(STMotion.quick, value: choice == .custom)
    }

    private var options: [STSegmentedOption<Choice>] {
        settings.presets.enumerated().map { STSegmentedOption(.preset($0.offset), $0.element.title) }
            + [STSegmentedOption(.custom, "Custom")]
    }

    /// The chips pick one: clicking another chip picks it, and clicking the picked one keeps it.
    private func selection(_ choice: Choice) -> Binding<Set<Choice>> {
        Binding(
            get: { [choice] },
            set: { picked in
                guard let new = picked.subtracting([choice]).first else { return }
                switch new {
                case .preset(let index) where settings.presets.indices.contains(index):
                    customPicked = false
                    settings.durationSeconds = settings.presets[index].seconds
                case .preset:
                    break
                case .custom:
                    customPicked = true
                }
            })
    }
}

/// A length of time typed as `H:MM:SS`, `M:SS` or plain seconds (`DurationText`), kept within 1 s – 99:59:59. Each
/// valid entry is written at once; one that isn't a length is marked and left unwritten, and Return puts back the
/// stored value's own spelling.
struct TimerDurationField: View {
    @Binding var seconds: Int
    let label: String
    var width: CGFloat = 112
    @State private var text: String

    init(seconds: Binding<Int>, label: String, width: CGFloat = 112) {
        _seconds = seconds
        self.label = label
        self.width = width
        _text = State(initialValue: DurationText.format(seconds.wrappedValue))
    }

    var body: some View {
        STTextField(label, text: $text, isInvalid: DurationText.parse(text) == nil)
            .frame(width: width)
            .onChange(of: seconds) { _, new in
                if DurationText.parse(text) != new { text = DurationText.format(new) }
            }
            .onChange(of: text) { _, new in
                if let parsed = DurationText.parse(new), parsed != seconds { seconds = parsed }
            }
            .onSubmit { text = DurationText.format(seconds) }
            .accessibilityLabel(label)
    }
}
