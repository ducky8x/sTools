import SwiftUI

/// What a key cap is doing, for the view around it to say: nothing, listening for a key, or listening still after
/// refusing the last key, with the reason.
public enum STKeyCapActivity: Equatable, Sendable {
    case idle
    case listening
    case refused(String)

    /// What the recorder's state says.
    init(_ model: STShortcutRecorderModel) {
        guard model.isRecording else {
            self = .idle
            return
        }
        self = model.message.map(STKeyCapActivity.refused) ?? .listening
    }
}

/// A hotkey drawn as a key cap ("⌘1"), the way the Key Rebinder draws a key: click it to record a new key in place.
/// While it listens it lights in the accent and shows the modifiers held so far; any known key, alone or with ⌃ ⌥ ⇧ ⌘,
/// commits, Esc cancels and Delete clears, as in `STShortcutRecorder`, whose rules and key monitor it shares. A click
/// anywhere else, or another app coming to the front, cancels. Without a key it reads Add Key on a dashed cap. Beside a
/// set key, a small × clears it.
///
/// `validate` refuses a key with a short reason; the cap keeps listening, turns red and reports the reason through
/// `activity`, so the view around it can show it. `isDimmed` draws the cap quieter (hotkeys are off, so the key does
/// nothing yet), and `problem` draws it in the danger color (the key is set but doesn't work). `spokenKey` is what
/// VoiceOver says for the key ("Command 1").
public struct STKeyCapRecorder: View {
    @Binding private var shortcut: STShortcut?
    @Binding private var activity: STKeyCapActivity
    private let label: String
    private let spokenKey: String?
    private let isDimmed: Bool
    private let problem: String?
    private let validate: (STShortcut) -> String?

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var model = STShortcutRecorderModel()
    @State private var monitor = STShortcutKeyMonitor()
    @State private var isHovering = false

    public init(shortcut: Binding<STShortcut?>, label: String, spokenKey: String? = nil, isDimmed: Bool = false,
                problem: String? = nil, activity: Binding<STKeyCapActivity> = .constant(.idle),
                validate: ((STShortcut) -> String?)? = nil) {
        _shortcut = shortcut
        _activity = activity
        self.label = label
        self.spokenKey = spokenKey
        self.isDimmed = isDimmed
        self.problem = problem
        self.validate = validate ?? STShortcutRecorderLogic.basicRejection
    }

    public var body: some View {
        HStack(spacing: 4 * theme.textScale) {
            cap
            if shortcut != nil && !model.isRecording {
                clearButton
            }
        }
        .stAnimation(STMotion.quick, value: model.isRecording)
        .onChange(of: model) { _, current in
            let now = STKeyCapActivity(current)
            if activity != now { activity = now }
        }
    }

    // MARK: The cap

    private var cap: some View {
        let shape = RoundedRectangle(cornerRadius: 6 * theme.textScale, style: .continuous)
        return capLabel
            .lineLimit(1)
            .padding(.horizontal, 9 * theme.textScale)
            .frame(minWidth: 34 * theme.textScale, minHeight: 24 * theme.textScale)
            .background {
                if shortcut == nil && !model.isRecording {
                    shape.fill(Color.clear)
                } else {
                    shape.fill(model.isRecording ? theme.accent.opacity(0.14) : STColor.raised)
                }
            }
            .overlay { capEdge(shape) }
            .overlay {
                shape.stroke(theme.accentStroke, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused && isEnabled ? 1 : 0)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .focusable(isEnabled)
            .focused($isFocused)
            .focusEffectDisabled()
            // Outside the focus modifiers, as on `STShortcutRecorder`: inside them the click only gives focus.
            .onTapGesture(perform: startRecording)
            .onKeyPress(.return) {
                guard !model.isRecording else { return .ignored }
                startRecording()
                return .handled
            }
            .onChange(of: model.isRecording) { _, recording in
                if recording { startMonitoring() } else { monitor.stop() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { stopRecording() }
            }
            .onDisappear { stopRecording() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(model.isRecording
                ? "Press the new key or combination. Escape cancels, Delete clears."
                : "Activate to record a new key.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, startRecording)
            .accessibilityAction(named: "Clear key") { clear() }
    }

    @ViewBuilder private var capLabel: some View {
        if model.isRecording {
            // Red once a key was refused, until the next key goes down or a modifier changes.
            let isRefusing = model.message != nil
            if model.heldModifiers.isEmpty {
                Text("Press a key").stStyle(.label).foregroundStyle(isRefusing ? STColor.danger : theme.accent)
            } else {
                Text(model.heldModifiers.symbols).font(keyFont).foregroundStyle(isRefusing ? STColor.danger : STColor.ink)
            }
        } else if let shortcut {
            Text(shortcut.display)
                .font(keyFont)
                .foregroundStyle(problem != nil ? STColor.danger : (isDimmed ? theme.inkTertiary : STColor.ink))
        } else {
            HStack(spacing: 4 * theme.textScale) {
                Image(systemName: "plus")
                    .font(.system(size: 9 * theme.textScale, weight: .bold))
                    .accessibilityHidden(true)
                Text("Add Key").stStyle(.label)
            }
            .foregroundStyle(isHovering ? theme.accent : theme.inkSecondary)
        }
    }

    /// The cap's edge: the accent while it listens or is hovered, red while refusing a key or for a key that doesn't
    /// work, dashed while there is no key, and quieter while hotkeys are off.
    @ViewBuilder private func capEdge(_ shape: RoundedRectangle) -> some View {
        if model.isRecording {
            shape.strokeBorder(model.message != nil ? STColor.danger : theme.accentStroke, lineWidth: 1.5)
        } else if shortcut == nil {
            shape.strokeBorder(isHovering ? theme.accentStroke : theme.stroke,
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
        } else if problem != nil {
            shape.strokeBorder(STColor.danger, lineWidth: 1.5)
        } else {
            shape.strokeBorder(isHovering ? theme.accentStroke : (isDimmed ? STColor.rule : theme.stroke.opacity(0.7)),
                               lineWidth: 1)
        }
    }

    private var keyFont: Font { STFont.figures(13 * theme.textScale, weight: .medium) }

    private var clearButton: some View {
        Button(action: clear) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12 * theme.textScale))
                .frame(width: 18 * theme.textScale, height: 24 * theme.textScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(STKeyCapClearStyle())
        .focusEffectDisabled()
        .help("Clear the key")
        .accessibilityLabel("Clear \(label)")
    }

    private var accessibilityValue: String {
        if model.isRecording { return model.message ?? "Recording" }
        guard let shortcut else { return "Not set" }
        let key = spokenKey ?? shortcut.display
        guard let problem else { return key }
        return "\(key), not working: \(problem)"
    }

    // MARK: Recording

    private func clear() {
        stopRecording()
        guard shortcut != nil else { return }
        shortcut = nil
        sound.play(.click)
    }

    private func startRecording() {
        guard isEnabled, !model.isRecording else { return }
        isFocused = true
        model.begin()
    }

    private func stopRecording() {
        guard model.isRecording else { return }
        model.cancel()
        monitor.stop()
    }

    private func startMonitoring() {
        monitor.start { event in
            switch event {
            case .flagsChanged(let modifiers):
                model.flagsChanged(modifiers)
            case .interrupted:
                stopRecording()
            case .keyDown(let keyCode, let modifiers):
                switch model.keyDown(keyCode: keyCode, modifiers: modifiers, validate: validate) {
                case .commit(let recorded):
                    shortcut = recorded
                    sound.play(.click)
                case .clear:
                    shortcut = nil
                case .none:
                    break
                }
            }
        }
    }
}

/// The × beside a key cap: the accent while hovered, and a press dip.
private struct STKeyCapClearStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        STKeyCapClearBody(configuration: configuration)
    }
}

private struct STKeyCapClearBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.stTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovering ? theme.accent : theme.inkTertiary)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .stAnimation(STMotion.press, value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}
