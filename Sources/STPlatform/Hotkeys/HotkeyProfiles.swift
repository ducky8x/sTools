import Foundation

/// The Key Rebinder's Karabiner profiles as profile hotkeys need them (spec 6.1): whether Karabiner-Elements can switch
/// profiles now, the profiles' names in its order and the one in use. The Key Rebinder reads them without loading
/// karabiner.json, so they are there while its page is closed, and hands them over as `HotkeyAdvising.profiles`.
public struct HotkeyProfiles: Equatable, Sendable {
    /// Why no profile can be switched to now.
    public enum Problem: Equatable, Sendable {
        /// Karabiner-Elements isn't installed.
        case notInstalled
        /// Its command-line tool doesn't answer.
        case notRunning
        /// It is older than 16.0, the version the Key Rebinder needs; `found` is the version it reported.
        case versionTooOld(found: String)
        /// karabiner.json is missing or can't be read.
        case configUnreadable
        /// karabiner.json is a symbolic link, which the Key Rebinder never changes (spec 5.5.3).
        case linkedFile
        /// Karabiner-Elements lists no profiles.
        case noProfiles
    }

    public enum State: Equatable, Sendable {
        /// Not read yet. Nothing is said about a hotkey's profile until it is.
        case unknown
        /// Karabiner-Elements can switch to any of `names`.
        case ready
        /// No profile can be switched to now.
        case unavailable(Problem)
    }

    public var state: State
    /// Every profile's name, in Karabiner's order (`karabiner_cli --list-profile-names`).
    public var names: [String]
    /// The profile in use, when known.
    public var current: String?

    public init(state: State, names: [String] = [], current: String? = nil) {
        self.state = state
        self.names = names
        self.current = current
    }

    /// Nothing read yet.
    public static let unknown = HotkeyProfiles(state: .unknown)
    /// What there is without a Key Rebinder to ask: no Karabiner-Elements.
    public static let withoutKeyRebinder = HotkeyProfiles(state: .unavailable(.notInstalled))

    /// What keeps a press of `action` from switching profiles now: no profile can be switched to, or none has the name it
    /// switches to (renamed or deleted in Karabiner-Elements). Nil when it would switch, and while nothing is known.
    public func issue(with action: HotkeyProfileAction) -> HotkeyProfileIssue? {
        switch state {
        case .unknown: return nil
        case .unavailable(let problem): return .unavailable(problem)
        case .ready:
            if case .select(let name) = action, !names.contains(name) { return .missing(name) }
            return nil
        }
    }

    /// The profile Next profile goes to from `current`: the one after it in `names`, and after the last, the first. The
    /// first when `current` isn't listed; nil when nothing is.
    public static func next(after current: String?, in names: [String]) -> String? {
        guard let first = names.first else { return nil }
        guard let current, let index = names.firstIndex(of: current) else { return first }
        return names[(index + 1) % names.count]
    }
}

/// What keeps a hotkey's profile action from working now.
public enum HotkeyProfileIssue: Equatable, Sendable {
    /// No profile can be switched to.
    case unavailable(HotkeyProfiles.Problem)
    /// Karabiner-Elements lists no profile with this name.
    case missing(String)
}

/// What one press of a profile hotkey did (spec 6.1), as the Key Rebinder reports it for the confirmation over the game.
public enum HotkeyProfileSwitch: Equatable, Sendable {
    /// Karabiner-Elements uses this profile now.
    case switched(to: String)
    /// It already used this profile, so nothing changed.
    case alreadyCurrent(String)
    /// Next profile, with this the only profile: nothing changed.
    case onlyProfile(String)
    /// No profile has this name now, so nothing changed.
    case missing(String)
    /// No profile can be switched to, so nothing changed.
    case unavailable(HotkeyProfiles.Problem)
    /// The Key Rebinder was writing karabiner.json, so this press changed nothing.
    case busy
    /// Karabiner-Elements' command-line tool didn't switch to this profile.
    case failed(String)

    /// Whether Karabiner-Elements now uses another profile.
    public var changedProfile: Bool {
        if case .switched = self { true } else { false }
    }
}
