import Foundation

/// The three tools a hotkey toggles. Tool modules are not importable from STPlatform, so the
/// app maps each case to the real `ToolController`. The raw value is the stored name.
public enum HotkeyTool: String, Codable, CaseIterable, Hashable, Sendable {
    case nbbOverlay
    case windowBackdrop
    case crosshair
}

/// One thing a hotkey does.
public enum HotkeyAction: Hashable, Sendable {
    case toggle(HotkeyTool)
    /// Screen Recording's one action, "Screen Recording" in the editors (spec 6.1). The tool has no toggle of its
    /// own: a press starts a recording, switching the tool on first when it's off, and a press while recording
    /// stops it, which asks Save or Delete and then switches the tool off (spec 5.4.4).
    case startStopRecording
    /// Timer Overlay's key (spec 5.6.2). The tool has no toggle: the timer's own press table decides what a press
    /// does, and a press switches the tool on when it's off.
    case startTimer

    /// Every action, in the order a picker should list them.
    public static var allCases: [HotkeyAction] {
        HotkeyTool.allCases.map(HotkeyAction.toggle) + [.startStopRecording, .startTimer]
    }
}

/// Stored as one plain string: `toggle.crosshair`, `startStopRecording` or `startTimer`.
///
/// Builds before the merge had two Screen Recording actions, "Toggle Screen Recording" (`toggle.screenRecording`)
/// and "Start/stop recording" (`startStopRecording`). Both read as the one action now, so a hotkey that had both
/// keeps one, and the action is written as `startStopRecording`, which those builds still read.
extension HotkeyAction: Codable {
    private static let togglePrefix = "toggle."
    private static let recordingName = "startStopRecording"
    private static let oldRecordingToggleName = "toggle.screenRecording"
    private static let timerName = "startTimer"

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text == Self.recordingName || text == Self.oldRecordingToggleName {
            self = .startStopRecording
        } else if text == Self.timerName {
            self = .startTimer
        } else if text.hasPrefix(Self.togglePrefix),
                  let tool = HotkeyTool(rawValue: String(text.dropFirst(Self.togglePrefix.count))) {
            self = .toggle(tool)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown hotkey action \"\(text)\""))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .toggle(let tool): try container.encode(Self.togglePrefix + tool.rawValue)
        case .startStopRecording: try container.encode(Self.recordingName)
        case .startTimer: try container.encode(Self.timerName)
        }
    }
}

extension Sequence where Element == HotkeyAction {
    /// The actions with repeats removed, keeping the first occurrence of each (a set that remembers order).
    public var uniqued: [HotkeyAction] {
        var seen = Set<HotkeyAction>()
        return filter { seen.insert($0).inserted }
    }
}

/// One tool's new state, as decided by `HotkeyAction.resolve`.
public struct HotkeyToolChange: Equatable, Sendable {
    public let tool: HotkeyTool
    public let isOn: Bool

    public init(tool: HotkeyTool, isOn: Bool) {
        self.tool = tool
        self.isOn = isOn
    }
}

/// What a hotkey press should do.
public struct HotkeyOutcome: Equatable, Sendable {
    /// Every switchable tool in the action set, in action order, with its new state.
    public var toolChanges: [HotkeyToolChange]
    /// Whether to start or stop recording (Screen Recording's action flips on its own, apart from the tools).
    public var togglesRecording: Bool
    /// Whether to send Start timer (it acts on its own too; the timer's press table decides what it does).
    public var startsTimer: Bool

    public init(toolChanges: [HotkeyToolChange], togglesRecording: Bool, startsTimer: Bool = false) {
        self.toolChanges = toolChanges
        self.togglesRecording = togglesRecording
        self.startsTimer = startsTimer
    }
}

extension HotkeyAction {
    /// Toggle semantics for an action set (spec 6.1): if any switchable tool in the set is off, turn all
    /// of them on; otherwise turn all of them off. A tool missing from `toolStates` counts as off.
    /// Screen Recording's `startStopRecording` and `startTimer` never take part in that decision.
    public static func resolve(_ actions: [HotkeyAction], toolStates: [HotkeyTool: Bool]) -> HotkeyOutcome {
        var tools: [HotkeyTool] = []
        var recording = false
        var timer = false
        for action in actions.uniqued {
            switch action {
            case .toggle(let tool): tools.append(tool)
            case .startStopRecording: recording = true
            case .startTimer: timer = true
            }
        }
        let anyOff = tools.contains { toolStates[$0] != true }
        return HotkeyOutcome(toolChanges: tools.map { HotkeyToolChange(tool: $0, isOn: anyOff) },
                             togglesRecording: recording, startsTimer: timer)
    }
}
