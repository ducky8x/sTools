import Foundation
import STPlatform

/// Hotkeys that switch Karabiner-Elements' profile (spec 6.1). A press goes through the page's profile menu's own switch
/// (spec 5.5.6): Karabiner-Elements' command-line tool selects the profile and writes karabiner.json itself.
///
/// A press can come while the page is closed, so it never goes by what the page last read: it reads Karabiner's state,
/// the profiles and the one in use again. The editors and the rows ask for the same read, which never loads karabiner.json
/// into the controller: the status check parses the file to see that it can be read and lets it go, and the names come
/// from the command-line tool. A press that can't switch changes nothing and writes nothing. Every press is logged.
extension KeyRebinderController {
    private static let log = STLog.logger("Hotkeys")

    /// The profiles as hotkeys see them, from the last read: whether Karabiner-Elements can switch profiles now, every
    /// profile's name in its order and the one in use. `.unknown` until the first read (the page's, or
    /// `refreshProfiles()`).
    public var profiles: HotkeyProfiles {
        let state: HotkeyProfiles.State = switch requirement {
        case nil: .unknown
        case .notInstalled?: .unavailable(.notInstalled)
        case .notRunning?: .unavailable(.notRunning)
        case .versionTooOld(let found)?: .unavailable(.versionTooOld(found: found))
        case .configUnreadable?: .unavailable(.configUnreadable)
        case .ready?:
            if configIsSymbolicLink {
                .unavailable(.linkedFile)
            } else if profileNames.isEmpty {
                .unavailable(.noProfiles)
            } else {
                .ready
            }
        }
        return HotkeyProfiles(state: state, names: profileNames, current: currentProfile)
    }

    /// Reads Karabiner-Elements' state, its profiles' names and the one in use again, without loading karabiner.json. A
    /// call that comes while a read is under way waits for that one instead of starting another.
    public func refreshProfiles() async {
        if let reading = profileRead {
            await reading.value
            return
        }
        let reading = Task { await readProfiles() }
        profileRead = reading
        await reading.value
        if profileRead == reading { profileRead = nil }
    }

    /// One read. Each value is set only when it changed, so a read that finds nothing new redraws nothing. A read that a
    /// switch overlapped keeps the names and the profile in use the switch left, since it may have read them before.
    private func readProfiles() async {
        let switches = profileSwitches
        let status = await KarabinerStatus(probes: probes).evaluate()
        let linked = configFileIsSymbolicLink
        var names: [String]?
        var current: String?
        if status == .ready {
            names = try? await cli.listProfileNames()
            current = try? await cli.currentProfileName()
        }
        if requirement != status { requirement = status }
        if configIsSymbolicLink != linked { configIsSymbolicLink = linked }
        guard profileSwitches == switches else { return }
        if let names, names != profileNames { profileNames = names }
        if let current, profileNames.contains(current), current != currentProfile { currentProfile = current }
    }

    /// Switches Karabiner-Elements to the profile a hotkey's press asks for (spec 6.1): the one named, or the next one in
    /// Karabiner's order, from the last back to the first. Presses switch in turn, so a second Next profile goes on from
    /// where the first went.
    ///
    /// It switches only when the page's profile menu could: Karabiner-Elements ready, karabiner.json readable and not a
    /// symbolic link, and no other write under way, all read again for this press. Then the menu's own switch runs, and
    /// with the page open the file is read again, as after the menu. With the page closed nothing is loaded: the page
    /// reads the file when it opens. When it can't switch, or the profile is already in use, nothing changes and nothing is
    /// written.
    public func switchProfile(for action: HotkeyProfileAction) async -> HotkeyProfileSwitch {
        let earlier = profileSwitch
        let press = Task {
            _ = await earlier?.value
            return await performProfileSwitch(action)
        }
        profileSwitch = press
        let outcome = await press.value
        if profileSwitch == press { profileSwitch = nil }
        return outcome
    }

    private func performProfileSwitch(_ action: HotkeyProfileAction) async -> HotkeyProfileSwitch {
        let asked = HotkeyAction.profile(action).title
        // The profile menu or an edit is writing karabiner.json; Karabiner-Elements would write it at the same time.
        guard !isBusy else { return logged(.busy, asked: asked) }
        await refreshProfiles()
        let profiles = profiles
        let problem: HotkeyProfiles.Problem? = switch profiles.state {
        case .ready: nil
        case .unavailable(let problem): problem
        // A read always finds Karabiner-Elements' state; nothing known reads as its tool not answering.
        case .unknown: .notRunning
        }
        if let problem { return logged(.unavailable(problem), asked: asked) }
        let target: String
        switch action {
        case .select(let name):
            guard profiles.names.contains(name) else { return logged(.missing(name), asked: asked) }
            guard name != profiles.current else { return logged(.alreadyCurrent(name), asked: asked) }
            target = name
        case .next:
            guard let next = HotkeyProfiles.next(after: profiles.current, in: profiles.names) else {
                return logged(.unavailable(.noProfiles), asked: asked)
            }
            guard next != profiles.current else { return logged(.onlyProfile(next), asked: asked) }
            target = next
        }
        // Read again just now, so check once more: a write may have started while the read waited.
        guard !isBusy else { return logged(.busy, asked: asked) }
        isBusy = true
        defer { isBusy = false }
        do {
            try await select(target)
        } catch {
            Self.log.notice("Profile hotkey (\(asked, privacy: .public)): karabiner_cli did not switch to \(target, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(target)
        }
        if config != nil { await reloadConfig() }
        return logged(.switched(to: target), asked: asked)
    }

    /// Logs what a press did, with the action it asked for, and returns it.
    private func logged(_ outcome: HotkeyProfileSwitch, asked: String) -> HotkeyProfileSwitch {
        let what = switch outcome {
        case .switched(let name): "switched to \(name)"
        case .alreadyCurrent(let name): "nothing changed, \(name) is the profile in use"
        case .onlyProfile(let name): "nothing changed, \(name) is the only profile"
        case .missing(let name): "nothing changed, no profile is named \(name)"
        case .unavailable(let problem): "nothing changed, \(HotkeyWording.profileProblem(problem))"
        case .busy: "nothing changed, the Key Rebinder was writing karabiner.json"
        case .failed(let name): "karabiner_cli did not switch to \(name)"
        }
        Self.log.notice("Profile hotkey (\(asked, privacy: .public)): \(what, privacy: .public)")
        return outcome
    }
}
