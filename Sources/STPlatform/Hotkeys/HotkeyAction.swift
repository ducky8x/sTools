import Foundation

/// The three tools a hotkey toggles, in sidebar order. Tool modules are not importable from STPlatform, so the
/// app maps each case to the real `ToolController`. The raw value is the stored name.
public enum HotkeyTool: String, Codable, CaseIterable, Hashable, Sendable {
    case crosshair
    case nbbOverlay
    case windowBackdrop
}

/// What a hotkey does with the Key Rebinder's Karabiner profiles (spec 6.1). Karabiner-Elements gives a profile no
/// identity but its name, so the name is what a hotkey keeps, and what it switches to when pressed.
public enum HotkeyProfileAction: Hashable, Sendable {
    /// Switch to the profile with this name.
    case select(String)
    /// Switch to the profile after the current one, in Karabiner's order, and from the last back to the first.
    case next
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
    /// Switch the Key Rebinder's Karabiner profile (spec 6.1). It isn't one of `allCases`, the tools' actions: it takes a
    /// profile, belongs to no key set and never takes part in the toggle rule. A hotkey has one at most.
    case profile(HotkeyProfileAction)

    /// Every action, one per tool with a switch, in the order a picker should list them: the sidebar's (Crosshair,
    /// Timer Overlay's Start timer, NBB Overlay, Screen Recording, Window Backdrop; the app's `ToolID` holds that
    /// order, which a test checks this against), the order the key sets give the tools their keys in
    /// (`HotkeyKeySet.toolActions`).
    public static let allCases: [HotkeyAction] = [
        .toggle(.crosshair), .startTimer, .toggle(.nbbOverlay), .startStopRecording, .toggle(.windowBackdrop),
    ]

    /// The profile action this is, or nil for a tool's action.
    public var profileAction: HotkeyProfileAction? {
        if case .profile(let action) = self { action } else { nil }
    }

    /// `actions` in the order both editors save them: the tools' actions in sidebar order (`allCases`), then the first
    /// profile action, the one a hotkey can have.
    public static func pickerOrder(_ actions: some Sequence<HotkeyAction>) -> [HotkeyAction] {
        let chosen = Array(actions)
        return allCases.filter(chosen.contains) + chosen.lazy.filter { $0.profileAction != nil }.prefix(1)
    }
}

/// Stored as one plain string: `toggle.crosshair`, `startStopRecording`, `startTimer`, `selectProfile.` and the profile's
/// name (`selectProfile.Minecraft`), or `nextProfile`.
///
/// Builds before the merge had two Screen Recording actions, "Toggle Screen Recording" (`toggle.screenRecording`)
/// and "Start/stop recording" (`startStopRecording`). Both read as the one action now, so a hotkey that had both
/// keeps one, and the action is written as `startStopRecording`, which those builds still read.
///
/// A build from before profile actions reads `selectProfile.…` and `nextProfile` as actions it doesn't know and drops
/// them from their hotkey (`HotkeyBinding`'s lossy decoding), keeping the hotkey, its key and the rest of the list. So
/// `hotkeys.json` stays at version 3: at version 4 such a build would set the whole list aside instead.
extension HotkeyAction: Codable {
    private static let togglePrefix = "toggle."
    private static let recordingName = "startStopRecording"
    private static let oldRecordingToggleName = "toggle.screenRecording"
    private static let timerName = "startTimer"
    private static let selectProfilePrefix = "selectProfile."
    private static let nextProfileName = "nextProfile"

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text == Self.recordingName || text == Self.oldRecordingToggleName {
            self = .startStopRecording
        } else if text == Self.timerName {
            self = .startTimer
        } else if text == Self.nextProfileName {
            self = .profile(.next)
        } else if text.hasPrefix(Self.selectProfilePrefix) {
            self = .profile(.select(String(text.dropFirst(Self.selectProfilePrefix.count))))
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
        case .profile(.select(let name)): try container.encode(Self.selectProfilePrefix + name)
        case .profile(.next): try container.encode(Self.nextProfileName)
        }
    }
}

extension Sequence where Element == HotkeyAction {
    /// The actions with repeats removed, keeping the first occurrence of each (a set that remembers order).
    public var uniqued: [HotkeyAction] {
        var seen = Set<HotkeyAction>()
        return filter { seen.insert($0).inserted }
    }

    /// The actions as one hotkey keeps them: repeats removed (`uniqued`), and of the profile actions only the first, since
    /// a press switches to one profile.
    public var uniquedWithOneProfile: [HotkeyAction] {
        var hasProfile = false
        return uniqued.filter { action in
            guard action.profileAction != nil else { return true }
            defer { hasProfile = true }
            return !hasProfile
        }
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
    /// The Karabiner profile to switch to, when the set has a profile action. It acts on its own too.
    public var profile: HotkeyProfileAction?

    public init(toolChanges: [HotkeyToolChange], togglesRecording: Bool, startsTimer: Bool = false,
                profile: HotkeyProfileAction? = nil) {
        self.toolChanges = toolChanges
        self.togglesRecording = togglesRecording
        self.startsTimer = startsTimer
        self.profile = profile
    }
}

extension HotkeyAction {
    /// Toggle semantics for an action set (spec 6.1): if any switchable tool in the set is off, turn all
    /// of them on; otherwise turn all of them off. A tool missing from `toolStates` counts as off.
    /// Screen Recording's `startStopRecording`, `startTimer` and a profile action never take part in that decision. A
    /// set with several profile actions switches to the first one's profile.
    public static func resolve(_ actions: [HotkeyAction], toolStates: [HotkeyTool: Bool]) -> HotkeyOutcome {
        var tools: [HotkeyTool] = []
        var recording = false
        var timer = false
        var profile: HotkeyProfileAction?
        for action in actions.uniqued {
            switch action {
            case .toggle(let tool): tools.append(tool)
            case .startStopRecording: recording = true
            case .startTimer: timer = true
            case .profile(let wanted): profile = profile ?? wanted
            }
        }
        let anyOff = tools.contains { toolStates[$0] != true }
        return HotkeyOutcome(toolChanges: tools.map { HotkeyToolChange(tool: $0, isOn: anyOff) },
                             togglesRecording: recording, startsTimer: timer, profile: profile)
    }
}
