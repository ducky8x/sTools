import Foundation

extension HotkeyWording {
    /// The label of both editors' row for a hotkey's Karabiner profile, under the action chips (spec 6.1).
    public static let profileChoiceLabel = "Karabiner profile"
    /// The row's first option, the default: the hotkey leaves the profile as it is.
    public static let noProfileTitle = "None"
    /// The action that goes on to the next profile: its option in the row, and its name in a summary.
    public static let nextProfileTitle = "Next profile"

    /// Why no profile can be switched to, as a hotkey's row, the editors and the confirmation over the game say it:
    /// "Karabiner-Elements isn’t running".
    public static func profileProblem(_ problem: HotkeyProfiles.Problem) -> String {
        switch problem {
        case .notInstalled: "Karabiner-Elements isn\u{2019}t installed"
        case .notRunning: "Karabiner-Elements isn\u{2019}t running"
        case .versionTooOld(let found): "Karabiner-Elements \(found) is too old"
        case .configUnreadable: "karabiner.json can\u{2019}t be read"
        case .linkedFile: "karabiner.json is a symbolic link"
        case .noProfiles: "Karabiner-Elements has no profiles"
        }
    }

    /// A hotkey switches to a profile Karabiner-Elements no longer lists, renamed or deleted there: "No profile named
    /// “Minecraft”".
    public static func missingProfile(_ name: String) -> String {
        "No profile named \u{201C}\(name)\u{201D}"
    }

    /// What keeps a hotkey's profile action from working, for its row: "No profile named “Minecraft”", "Karabiner-Elements
    /// isn’t running". Nil when it has none, when it would work, and while the profiles aren't known yet.
    public static func profileNote(for actions: [HotkeyAction], in profiles: HotkeyProfiles) -> String? {
        guard let action = actions.lazy.compactMap(\.profileAction).first else { return nil }
        return switch profiles.issue(with: action) {
        case .unavailable(let problem)?: profileProblem(problem)
        case .missing(let name)?: missingProfile(name)
        case nil: nil
        }
    }

    /// The one problem a hotkey's row shows: why its key isn't registered (`statusNote(_:combo:inList:)`), else what keeps
    /// its profile action from working (`profileNote(for:in:)`). Nil when there is neither.
    public static func statusNote(_ status: HotkeyStatus?, for binding: HotkeyBinding, profiles: HotkeyProfiles,
                                  inList: Bool) -> String? {
        statusNote(status, combo: binding.combo, inList: inList) ?? profileNote(for: binding.actions, in: profiles)
    }
}

/// The Karabiner profile row both hotkey editors show under the action chips (spec 6.1): None, the default, then Next
/// profile and each profile by name, in Karabiner's order. One choice, since a hotkey switches to one profile.
///
/// The hotkey's own choice stays in view when Karabiner-Elements doesn't list it, so it can be seen and changed: a profile
/// renamed or deleted in Karabiner-Elements, or any choice while no profile can be switched to. Nothing in the list
/// changes because a profile went away. When there is nothing to choose, no options show and the note stands in their
/// place.
public struct HotkeyProfileChoice: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        /// Nil for None.
        public let value: HotkeyProfileAction?
        public let title: String
    }

    /// The options in view; none when there is nothing to choose.
    public let options: [Option]
    /// One line about the choice: why no profile can be switched to, or that the chosen one isn't there now. Nil when
    /// there is nothing to say.
    public let note: String?

    /// - Parameter selection: the editor's choice, nil for None.
    public init(profiles: HotkeyProfiles, selection: HotkeyProfileAction?) {
        var values: [HotkeyProfileAction?] = [nil]
        if profiles.state == .ready {
            values.append(.next)
            values += profiles.names.map { .select($0) }
        }
        if let selection, !values.contains(selection) { values.append(selection) }
        options = values.count > 1 ? values.map { Option(value: $0, title: Self.title(of: $0)) } : []

        switch profiles.state {
        case .unknown:
            note = "Reading Karabiner-Elements\u{2019} profiles\u{2026}"
        case .unavailable(let problem):
            note = HotkeyWording.profileProblem(problem) + ", so hotkeys can\u{2019}t switch profiles."
        case .ready:
            if case .select(let name)? = selection, !profiles.names.contains(name) {
                note = HotkeyWording.missingProfile(name) + " now, so a press changes nothing."
            } else {
                note = nil
            }
        }
    }

    /// An option's title: None, Next profile, or the profile's name.
    public static func title(of value: HotkeyProfileAction?) -> String {
        switch value {
        case nil: HotkeyWording.noProfileTitle
        case .next?: HotkeyWording.nextProfileTitle
        case .select(let name)?: name
        }
    }
}
