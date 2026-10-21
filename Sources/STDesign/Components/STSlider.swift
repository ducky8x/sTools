import SwiftUI

/// Pure slider arithmetic: stepping, clamping and the value/fraction mapping.
public enum STSliderMath {
    /// Clamps `value` into `range`, then rounds it to the nearest multiple of `step` measured from the lower bound.
    /// The upper bound stays reachable when it is not on a step. A non-positive or non-finite `step` only clamps;
    /// a NaN value yields the lower bound.
    public static func snapped(_ value: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard !value.isNaN, upper > lower else { return lower }
        let clamped = min(max(value, lower), upper)
        guard step > 0, step.isFinite else { return clamped }
        let steps = ((clamped - lower) / step).rounded()
        let candidate = min(cleaned(lower + steps * step), upper)
        return upper - clamped < abs(clamped - candidate) ? upper : candidate
    }

    /// Where `value` sits in `range`, from 0 (lower bound) to 1 (upper bound). A zero-width range yields 0.
    public static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let width = range.upperBound - range.lowerBound
        guard width > 0, !value.isNaN else { return 0 }
        return min(max((value - range.lowerBound) / width, 0), 1)
    }

    /// The snapped value at `fraction` (clamped to 0...1) along `range`.
    public static func value(atFraction fraction: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        let f = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        return snapped(range.lowerBound + f * (range.upperBound - range.lowerBound), in: range, step: step)
    }

    /// `value` moved by a whole number of steps (negative moves down), snapped and clamped. Used by arrow keys,
    /// the − / + buttons and the accessibility adjustable action.
    static func adjusted(_ value: Double, by steps: Int, in range: ClosedRange<Double>, step: Double) -> Double {
        let delta = step > 0 && step.isFinite ? Double(steps) * step : 0
        return snapped(value + delta, in: range, step: step)
    }

    /// The 0...1 fraction for a pointer at `x` over a track `trackWidth` wide whose thumb travels
    /// between `inset` and `trackWidth - inset`.
    static func fraction(atX x: Double, trackWidth: Double, inset: Double) -> Double {
        let usable = trackWidth - 2 * inset
        guard usable > 0 else { return 0 }
        return min(max((x - inset) / usable, 0), 1)
    }

    /// What committing typed text does.
    enum Commit: Equatable {
        /// A valid entry, already clamped to the range and snapped to the step.
        case value(Double)
        /// Nothing was typed: leave the value alone and close the field without complaint.
        case revert
        /// The text could not be understood: shake, then put the old value back.
        case invalid
    }

    /// Turns typed text into a committed value: blank text reverts, text `parse` rejects (or that parses to
    /// a non-finite number) is invalid, anything else is clamped and snapped like every other input path.
    static func commit(_ text: String,
                       in range: ClosedRange<Double>,
                       step: Double,
                       parse: (String) -> Double?) -> Commit {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .revert }
        guard let parsed = parse(text), parsed.isFinite else { return .invalid }
        return .value(snapped(parsed, in: range, step: step))
    }

    /// Rounds away floating-point residue such as 0.30000000000000004.
    private static func cleaned(_ value: Double) -> Double {
        (value * 1e9).rounded() / 1e9
    }
}

/// A thin track with an accent fill, a round thumb, a rolling monospaced readout and − / + steppers.
///
/// On its own the slider shows its label above the track. Where labels are hidden (`.labelsHidden()`, which
/// `STSettingsRow` applies so its own label names the control) it drops that line and sits on one line: the
/// track, then the steppers. VoiceOver reads `label` either way.
public struct STSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let label: String
    private let valueText: (Double) -> String
    private let parse: (String) -> Double?

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsVisibility) private var labelsVisibility
    @FocusState private var isFocused: Bool
    @FocusState private var readoutFocused: Bool
    @FocusState private var entryFocused: Bool
    @State private var isDragging = false
    @State private var phase = EntryPhase.idle
    @State private var draft = ""
    @State private var shakes: CGFloat = 0

    /// Where the typed-entry field is: not shown, being edited, or showing a rejected entry while it shakes.
    private enum EntryPhase { case idle, editing, rejecting }

    private let thumbDiameter: CGFloat = 16
    private let trackHeight: CGFloat = 3

    /// Whole numbers stay whole; otherwise up to three decimals with no trailing zeros, in a fixed locale
    /// so the app reads the same everywhere.
    public nonisolated static func defaultValueText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never).locale(Locale(identifier: "en_US")))
    }

    /// Reads text typed into the readout. Surrounding whitespace is ignored, both "." and "," work as the
    /// decimal separator, and one trailing unit (letters, "%", "\u{00D7}", "\u{00B0}") is dropped: "85%", "85 %",
    /// "1.5x" and "12 px" read as 85, 85, 1.5 and 12. The number is returned as typed; pass a custom `parse`
    /// when the readout shows a scaled value (for example a 0...1 value displayed as a percentage).
    public nonisolated static func defaultParse(_ text: String) -> Double? {
        var number = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = number.last, last.isLetter || last.isWhitespace || "%\u{00D7}\u{00B0}".contains(last) {
            number = number.dropLast()
        }
        var isNegative = false
        var body = ""
        var hasSeparator = false
        for (index, character) in number.enumerated() {
            switch character {
            case "0"..."9":
                body.append(character)
            case "." where !hasSeparator, "," where !hasSeparator:
                hasSeparator = true
                body.append(".")
            case "-" where index == 0, "\u{2212}" where index == 0:
                isNegative = true
            case "+" where index == 0:
                break
            default:
                return nil
            }
        }
        guard body.contains(where: \.isNumber) else { return nil }
        if body.hasPrefix(".") { body.insert("0", at: body.startIndex) }
        if body.hasSuffix(".") { body.append("0") }
        return Double(body).map { isNegative ? -$0 : $0 }
    }

    /// `parse` reads text typed into the readout; see `defaultParse`.
    public init(value: Binding<Double>,
                in range: ClosedRange<Double>,
                step: Double = 1,
                label: String,
                valueText: @escaping (Double) -> String = STSlider.defaultValueText,
                parse: @escaping (String) -> Double? = STSlider.defaultParse) {
        _value = value
        self.range = range
        self.step = step
        self.label = label
        self.valueText = valueText
        self.parse = parse
    }

    /// Test hook: the same slider with its entry field already open.
    func startingInEditMode() -> STSlider {
        var copy = self
        copy._phase = State(initialValue: .editing)
        copy._draft = State(initialValue: valueText(value))
        return copy
    }

    /// The width of a slider in a settings row, steppers and readout included.
    public static let rowWidth: CGFloat = 260

    public var body: some View {
        Group {
            if labelsVisibility == .hidden {
                // In a settings row every slider is the same width, so the tracks line up down a page instead of
                // stretching to whatever the row's label leaves over.
                HStack(spacing: 12) {
                    track.frame(minWidth: 96)
                    steppers
                }
                .frame(maxWidth: Self.rowWidth)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(label)
                            .stStyle(.label)
                            .foregroundStyle(theme.inkSecondary)
                            .accessibilityHidden(true)
                        Spacer(minLength: 12)
                        steppers
                    }
                    track
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }

    /// − readout +.
    private var steppers: some View {
        HStack(spacing: 4) {
            Button("\u{2212}") { nudge(-1) }
                .buttonStyle(STButtonStyle(.quiet))
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("Decrease \(label)")
            readout
            Button("+") { nudge(1) }
                .buttonStyle(STButtonStyle(.quiet))
                .disabled(value >= range.upperBound)
                .accessibilityLabel("Increase \(label)")
        }
    }

    private var figuresFont: Font { STFont.figures(14 * theme.textScale) }

    @ViewBuilder private var readout: some View {
        if phase == .idle {
            Button(action: beginEditing) {
                // Sized to the wider of the two ends' texts, so the steppers (and, on one line, the track)
                // hold still while the value changes.
                ZStack {
                    Text(valueText(range.lowerBound)).font(figuresFont).hidden()
                    Text(valueText(range.upperBound)).font(figuresFont).hidden()
                    Text(valueText(value))
                        .font(figuresFont)
                        .foregroundStyle(STColor.ink)
                        .contentTransition(theme.reduceMotion ? .identity : .numericText(value: value))
                        .stAnimation(STMotion.quick, value: value)
                }
                .frame(minWidth: 44)
            }
            .buttonStyle(.plain)
            .focused($readoutFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                beginEditing()
                return .handled
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.accent).frame(height: 1).opacity(readoutFocused ? 1 : 0).allowsHitTesting(false)
            }
            .accessibilityLabel("Edit \(label)")
            .accessibilityValue(valueText(value))
            .accessibilityHint("Type a new value")
        } else {
            entryField
        }
    }

    /// The house text field look (surface fill, stroke baseline that turns to an accent underline on focus,
    /// danger underline and a shake when the entry is rejected) around a bare field, so focus, Return and
    /// Escape stay under this view's control.
    private var entryField: some View {
        let rejected = phase == .rejecting
        return TextField("\(label) value", text: $draft)
            .textFieldStyle(.plain)
            .font(figuresFont)
            .foregroundStyle(STColor.ink)
            .tint(theme.accent)
            .multilineTextAlignment(.trailing)
            .focused($entryFocused)
            .focusEffectDisabled()
            .frame(width: 64)
            .padding(.vertical, 2)
            .background(STColor.surface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(rejected ? STColor.danger : (entryFocused ? theme.accent : theme.stroke))
                    .frame(height: 1)
                    .stAnimation(STMotion.quick, value: entryFocused)
                    .allowsHitTesting(false)
            }
            .modifier(STShakeEffect(animatableData: shakes))
            .accessibilityHint(rejected ? "Invalid value" : "")
            .onAppear { entryFocused = true }
            .onSubmit { commitDraft() }
            .onExitCommand { finishEditing() }
            .onChange(of: entryFocused) { _, focused in
                if !focused { commitDraft() }
            }
            .task(id: phase) {
                guard phase == .rejecting else { return }
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { finishEditing() }
            }
    }

    private var track: some View {
        GeometryReader { proxy in
            let fraction = STSliderMath.fraction(of: value, in: range)
            let travel = max(proxy.size.width - thumbDiameter, 0)
            let thumbX = thumbDiameter / 2 + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(theme.stroke).frame(height: trackHeight)
                Capsule().fill(theme.accentStroke).frame(width: thumbX, height: trackHeight)
                Circle()
                    .fill(STColor.ink)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .scaleEffect(isDragging ? 1.25 : 1)
                    .stAnimation(STMotion.quick, value: isDragging)
                    .position(x: thumbX, y: proxy.size.height / 2)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(drag(trackWidth: proxy.size.width))
        }
        .frame(height: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.accentStroke, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        }
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .downArrow, .rightArrow, .upArrow]) { press in
            nudge(press.key == .leftArrow || press.key == .downArrow ? -1 : 1)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func drag(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard isEnabled else { return }
                isDragging = true
                let fraction = STSliderMath.fraction(atX: drag.location.x, trackWidth: trackWidth, inset: thumbDiameter / 2)
                set(STSliderMath.value(atFraction: fraction, in: range, step: step))
            }
            .onEnded { _ in isDragging = false }
    }

    private func nudge(_ steps: Int) {
        guard isEnabled else { return }
        set(STSliderMath.adjusted(value, by: steps, in: range, step: step))
    }

    private func beginEditing() {
        guard isEnabled, phase == .idle else { return }
        draft = valueText(value)
        phase = .editing
    }

    /// Return and focus loss. A rejected entry keeps the field up for one shake, with the old value back in it.
    private func commitDraft() {
        guard phase == .editing else { return }
        switch STSliderMath.commit(draft, in: range, step: step, parse: parse) {
        case .value(let committed):
            set(committed)
            finishEditing()
        case .revert:
            finishEditing()
        case .invalid:
            phase = .rejecting
            draft = valueText(value)
            if !theme.reduceMotion {
                withAnimation(STTypingMotion.shake) { shakes += 1 }
            }
        }
    }

    /// Closes the field. Keyboard focus goes back to the readout only if the field still had it, so
    /// clicking elsewhere never gets its focus stolen.
    private func finishEditing() {
        let hadFocus = entryFocused
        phase = .idle
        if hadFocus { readoutFocused = true }
    }

    private func set(_ newValue: Double) {
        guard newValue != value else { return }
        value = newValue
        sound.play(.tick)
    }
}
