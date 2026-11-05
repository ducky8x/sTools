import STDesign
import STPlatform
import ScreenRecording
import SwiftUI
import TimerOverlay

/// Home's tools in sidebar order, read row by row (spec 3.5): the six with a switch three to a row, then the Key Rebinder,
/// whose profile chips need the room, across the page.
enum HomeToolGrid {
    static let columns = 3

    static let rows: [[ToolID]] = {
        let switched = ToolID.allCases.filter(\.hasSwitch)
        let rows = stride(from: 0, to: switched.count, by: columns).map { start in
            Array(switched[start..<min(start + columns, switched.count)])
        }
        return rows + [ToolID.allCases.filter { !$0.hasSwitch }]
    }()

    /// The visual beside each row in a wide window, each by a row with a tool it serves: Ninjabrain Bot by the NBB
    /// Overlay, Minecraft by Screen Recording, Window Backdrop and Custom Cursor, which follow its window, and
    /// Karabiner-Elements by the Key Rebinder.
    static let lamps: [HomeLampKind] = [.ninjabrainBot, .minecraft, .karabiner]
}

/// One tool on Home: its number and name, its live status, its key as a key cap and its switch. Clicking the tile opens
/// the tool's page. The switch takes the sidebar's path, so Timer Overlay's starts a countdown and Screen Recording's a
/// recording. The key cap sets the tool's own hotkey as the tool page's Hotkey row does, with its refusals and words,
/// whether hotkeys are on or off. Without Accessibility a tool that needs it offers Allow… where its switch was.
struct HomeToolTile: View {
    let model: AppModel
    let tool: ToolID
    private let action: HotkeyAction?

    @Environment(\.stTheme) private var theme
    @Environment(\.homeTilesAreTight) private var isTight
    @State private var keyActivity: STKeyCapActivity = .idle
    @State private var isHovering = false

    init(model: AppModel, tool: ToolID) {
        self.model = model
        self.tool = tool
        action = tool.hotkeyAction
    }

    private var hotkeys: HotkeyCenter { model.hotkeys }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button(action: open) {
                HomeTileLabel(tool: tool, status: statusLine(keyActivity), isMessage: keyActivity != .idle)
            }
            .buttonStyle(HomeTileStyle(isHovering: isHovering, isLit: model.status(of: tool).isLit))
            .focusEffectDisabled()
            .accessibilityLabel(spokenTitle)
            .accessibilityValue(spokenStatus)
            .accessibilityHint("Opens the \(tool.title) page")
            controls
                // Under the name; in a tight tile, from the tile's edge, so Allow… fits beside the key.
                .padding(.leading, isTight ? HomeTileLabel.leadingPadding : HomeTileLabel.leading(theme.textScale))
                .padding(.trailing, HomeTileLabel.trailingPadding - 2)
                .padding(.bottom, HomeTileLabel.bottomPadding(tight: isTight))
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tool.title)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: isTight ? 4 : 8) {
            if let keyBinding {
                STKeyCapRecorder(shortcut: keyBinding, label: keyLabel, spokenKey: spokenKey, isDimmed: !hotkeys.isEnabled,
                                 problem: keyProblem, revealsClear: isHovering, activity: $keyActivity,
                                 validate: refusal(for:))
                    .help(keyHelp)
            }
            Spacer(minLength: isTight ? 0 : 4)
            if offersAllow {
                Button("Allow\u{2026}") { Task { await allowAccessibility() } }
                    .buttonStyle(STButtonStyle(.quiet))
                    .fixedSize()
                    .help(Self.allowHelp(tool))
                    .accessibilityLabel("Allow Accessibility for \(tool.title)")
                    .accessibilityHint(Self.allowHelp(tool))
            } else if tool.hasSwitch {
                STSwitch(isOn: Binding(get: { model.isOn(tool) }, set: { setSwitch($0) }), label: tool.title)
                    .disabled(!model.canSwitch(tool))
            }
        }
        .frame(height: HomeTileLabel.controlsHeight(theme.textScale))
    }

    // MARK: What the tile does

    /// The tile's switch: the same path as the sidebar's and the page's (`AppModel.switchBinding`).
    func setSwitch(_ on: Bool) {
        model.switchBinding(tool).wrappedValue = on
    }

    func open() {
        model.navigate(to: .tool(tool))
    }

    /// Whether Allow… stands where the switch was: the tool needs Accessibility (rule R10) and it isn't allowed.
    var offersAllow: Bool { tool.requiresAccessibility && !model.accessibilityGranted }

    /// Allow…'s help tag, the tool page's own sentence.
    static func allowHelp(_ tool: ToolID) -> String {
        "\(tool.title) needs Accessibility to find the Minecraft window."
    }

    func allowAccessibility() async {
        await model.allowAccessibility()
    }

    // MARK: The key

    /// The tool's own hotkey, set, changed or cleared through `ToolHotkey`, as on the tool's page. Nil for the Key
    /// Rebinder, whose hotkeys sit on its keys.
    var keyBinding: Binding<STShortcut?>? {
        guard let action else { return nil }
        return Binding(
            get: { ToolHotkey.own(for: action, in: model.hotkeys.bindings)?.combo.asSTShortcut },
            set: { ToolHotkey.set($0?.hotkeyCombo, for: action, in: model.hotkeys) })
    }

    /// Why the key cap refuses `shortcut` while it listens, in the tool page's words; nil when it's fine.
    func refusal(for shortcut: STShortcut) -> String? {
        guard let action else { return nil }
        return ToolHotkey.refusal(for: shortcut.hotkeyCombo, action: action, in: hotkeys)
    }

    private var ownKey: HotkeyBinding? {
        action.flatMap { ToolHotkey.own(for: $0, in: hotkeys.bindings) }
    }

    /// What's wrong with the tool's own key, as its page says it; nil when nothing is.
    var keyProblem: String? {
        guard let own = ownKey else { return nil }
        return HotkeyWording.statusNote(hotkeys.status(of: own.id), combo: own.combo, inList: false)
    }

    /// The key cap's name for VoiceOver.
    var keyLabel: String { "\(tool.title) hotkey" }

    /// The key as VoiceOver says it ("Command 1"); nil without one.
    var spokenKey: String? {
        ownKey.map { HotkeyWording.spokenName(for: $0.combo) }
    }

    /// The key cap's help tag: why the key does nothing yet, what it does where a toggle isn't all, and the notes the
    /// tool page shows under its key.
    private var keyHelp: String {
        guard let own = ownKey else { return "Click to give \(tool.title) a key." }
        var lines: [String] = []
        if let keyProblem { lines.append(Self.sentence(keyProblem)) }
        if !hotkeys.isEnabled { lines.append("Hotkeys are off, so this key does nothing yet.") }
        switch tool {
        case .timerOverlay:
            lines.append(TimerKeyLine.text(for: model.timerOverlay?.settings.cancelGesture ?? .doublePress))
        case .screenRecording:
            lines.append(ToolHotkeyRow.screenRecordingPurpose(asksSaveOrDelete: model.controller(
                for: .screenRecording, as: ScreenRecordingController.self)?.options.askSaveDelete ?? true))
        default:
            break
        }
        lines += hotkeys.notes(for: own.combo).map(\.text)
        lines.append("Click to change it.")
        return lines.joined(separator: " ")
    }

    // MARK: The status line

    /// What the line under the tool's name says, and in which tone.
    struct StatusLine: Equatable {
        enum Tone: Equatable { case quiet, accent, danger }
        var text: String
        var tone: Tone

        /// While a key cap listens, how to finish; after it refused a key, why. Nil while nothing listens.
        static func recording(_ activity: STKeyCapActivity) -> StatusLine? {
            switch activity {
            case .idle: nil
            case .listening: StatusLine(text: "Esc cancels, Delete clears", tone: .accent)
            case .refused(let reason): StatusLine(text: reason, tone: .danger)
            }
        }

        /// A tool's live status, lit while the tool is on.
        static func status(_ status: ToolStatus) -> StatusLine {
            StatusLine(text: status.label, tone: status.isLit ? .accent : .quiet)
        }
    }

    /// The tool's live status; while the key cap listens, how to finish; and why it refused a key.
    func statusLine(_ activity: STKeyCapActivity) -> StatusLine {
        StatusLine.recording(activity) ?? StatusLine.status(model.status(of: tool))
    }

    /// `text` as a sentence in a help tag: a hotkey's problem note ("Already used by another hotkey") gets its period.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".?!".contains(last) else { return text }
        return text + "."
    }

    // MARK: VoiceOver

    var spokenTitle: String { "\(tool.number), \(tool.title)" }
    var spokenStatus: String { model.status(of: tool).label.capitalized }
}

/// A tile's number, name and status line, with room under them for the controls drawn over the tile.
struct HomeTileLabel: View {
    let tool: ToolID
    let status: HomeToolTile.StatusLine
    /// A message in place of the status (how to finish recording a key, or why one was refused): in sentence case.
    let isMessage: Bool

    @Environment(\.stTheme) private var theme
    @Environment(\.homeTilesAreTight) private var isTight

    /// The tile's padding above its name and below its controls, and at its sides. A tight tile (the narrowest window)
    /// keeps less above and below.
    static func topPadding(tight: Bool) -> CGFloat { tight ? 8 : 12 }
    static func bottomPadding(tight: Bool) -> CGFloat { tight ? 6 : 10 }
    static let leadingPadding: CGFloat = 14
    static let trailingPadding: CGFloat = 12
    /// The least room between the status line and the controls.
    static func controlsGap(tight: Bool) -> CGFloat { tight ? 4 : 6 }

    /// Where the name, the status and the key cap start: past the number's column, as in the sidebar.
    static func leading(_ scale: Double) -> CGFloat { leadingPadding + numberColumn(scale) }

    /// The number's column and the room after it.
    static func numberColumn(_ scale: Double) -> CGFloat { (14 + 8) * scale }

    /// The controls' row: a switch is 30 pt tall with its padding.
    static func controlsHeight(_ scale: Double) -> CGFloat { max(30, 24 * scale + 6) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeTileHeading(tool: tool, status: status, isMessage: isMessage)
            Spacer(minLength: Self.controlsGap(tight: isTight))
            Color.clear.frame(height: Self.controlsHeight(theme.textScale))
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, Self.trailingPadding)
        .padding(.top, Self.topPadding(tight: isTight))
        .padding(.bottom, Self.bottomPadding(tight: isTight))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

/// A tile's number and name, and its status line under the name. In a tight tile the status starts at the tile's edge, and
/// a name too long for the tile gives way to its shortest form ("Timer", "NBB"); elsewhere it shrinks a little instead.
struct HomeTileHeading: View {
    let tool: ToolID
    let status: HomeToolTile.StatusLine
    let isMessage: Bool

    @Environment(\.stTheme) private var theme
    @Environment(\.homeTilesAreTight) private var isTight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(tool.number)")
                    .font(STFont.figures(16 * theme.textScale, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 14 * theme.textScale, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    name(tool.title)
                    name(tool.sidebarTitle).minimumScaleFactor(0.8)
                    if isTight { name(tool.shortestTitle).minimumScaleFactor(0.8) }
                }
            }
            statusText
                .padding(.leading, isTight ? 0 : HomeTileLabel.numberColumn(theme.textScale))
                .padding(.top, 2)
        }
    }

    private func name(_ text: String) -> some View {
        Text(text)
            .stStyle(.sidebarName)
            .foregroundStyle(STColor.ink)
            .lineLimit(1)
            .sidebarNameLine(scale: theme.textScale)
    }

    private var statusText: some View {
        let color: Color = switch status.tone {
        case .quiet: theme.inkTertiary
        case .accent: theme.accent
        case .danger: STColor.danger
        }
        // A message reads in sentence case; a status in small caps. Either wraps rather than cut off at larger text.
        return Text(status.text)
            .stStyle(isMessage ? .caption : .label)
            .foregroundStyle(color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A tile's look: the plate, the raised fill while the pointer is over it, an accent edge while its tool is on, the
/// house press dip and the accent focus ring.
struct HomeTileStyle: ButtonStyle {
    var isHovering = false
    var isLit = false

    func makeBody(configuration: Configuration) -> some View {
        HomeTileBody(configuration: configuration, isHovering: isHovering, isLit: isLit)
    }
}

private struct HomeTileBody: View {
    let configuration: ButtonStyleConfiguration
    let isHovering: Bool
    let isLit: Bool
    @Environment(\.stTheme) private var theme
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .background(shape.fill(isHovering ? STColor.raised : STColor.surface))
            .overlay { shape.strokeBorder(isLit ? theme.accentStroke.opacity(0.55) : STColor.rule, lineWidth: 1) }
            .overlay {
                shape.stroke(theme.accentStroke, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .stAnimation(STMotion.press, value: configuration.isPressed)
            .stAnimation(STMotion.quick, value: isHovering)
    }
}

extension EnvironmentValues {
    /// Whether Home's tiles sit tight, as they do in the narrowest window (`HomeLayout.tilesAreTight`).
    @Entry var homeTilesAreTight = false
}
