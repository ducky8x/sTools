import Foundation
import Testing
@testable import STPlatform

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])
private let f7 = HotkeyCombo(keyCode: 98, modifiers: [])
private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])
private let minecraft = HotkeyAction.profile(.select("Minecraft"))

/// Karabiner-Elements ready, with three profiles and Default profile in use.
private let ready = HotkeyProfiles(state: .ready, names: ["Default profile", "Minecraft", "Typing"], current: "Default profile")

/// The words for profile actions (spec 6.1), the same in both editors, the rows and the confirmation.
@Suite("Profile wording")
struct HotkeyProfileWordingTests {
    // MARK: Names

    @Test func theActionsAreNamedByWhatTheyDo() {
        #expect(minecraft.title == "Switch to Minecraft")
        #expect(HotkeyAction.profile(.next).title == "Next profile")
        #expect(HotkeyWording.summary([.toggle(.crosshair), minecraft]) == "Crosshair + Switch to Minecraft")
        #expect(HotkeyWording.spokenSummary([.toggle(.crosshair), .startTimer, .profile(.next)])
            == "Crosshair, Start timer and Next profile")
        #expect(minecraft.toolTitle == "Key Rebinder", "a profile belongs to the Key Rebinder")
    }

    @Test func theRowsLabelAndOptions() {
        #expect(HotkeyWording.profileChoiceLabel == "Karabiner profile")
        #expect(HotkeyProfileChoice.title(of: nil) == "None")
        #expect(HotkeyProfileChoice.title(of: .next) == "Next profile")
        #expect(HotkeyProfileChoice.title(of: .select("Typing")) == "Typing")
    }

    // MARK: One key of its own

    /// A profile has one key of its own, as a tool does: the question and what Replace does name the profile.
    @Test func theReplaceQuestionNamesTheProfile() {
        let own = HotkeyBinding(combo: f6, actions: [minecraft])
        #expect(HotkeyWording.replaceOwnKeyQuestion(own, with: f7) == "Use F7 to switch to Minecraft?")
        #expect(HotkeyWording.replaceOwnKeyWarning(own, with: f7)
            == "This replaces F6, the key that switches to Minecraft, with F7. Other hotkeys don\u{2019}t change.")
        let next = HotkeyBinding(combo: f6, actions: [.profile(.next)])
        #expect(HotkeyWording.replaceOwnKeyQuestion(next, with: f7) == "Use F7 for Next profile?")
        #expect(HotkeyWording.replaceOwnKeyWarning(next, with: f7)
            == "This replaces Next profile\u{2019}s key F6 with F7. Other hotkeys don\u{2019}t change.")
        // A tool's reads as it did.
        let crosshair = HotkeyBinding(combo: f6, actions: [.toggle(.crosshair)])
        #expect(HotkeyWording.replaceOwnKeyQuestion(crosshair, with: f7) == "Use F7 for Crosshair?")
        #expect(HotkeyWording.replaceOwnKeyWarning(crosshair, with: f7)
            == "This replaces Crosshair\u{2019}s key F6 with F7. Other hotkeys don\u{2019}t change.")
    }

    // MARK: Problems

    @Test func eachProblemInAFewWords() {
        #expect(HotkeyWording.profileProblem(.notInstalled) == "Karabiner-Elements isn\u{2019}t installed")
        #expect(HotkeyWording.profileProblem(.notRunning) == "Karabiner-Elements isn\u{2019}t running")
        #expect(HotkeyWording.profileProblem(.versionTooOld(found: "15.3.0")) == "Karabiner-Elements 15.3.0 is too old")
        #expect(HotkeyWording.profileProblem(.configUnreadable) == "karabiner.json can\u{2019}t be read")
        #expect(HotkeyWording.profileProblem(.linkedFile) == "karabiner.json is a symbolic link")
        #expect(HotkeyWording.profileProblem(.noProfiles) == "Karabiner-Elements has no profiles")
        #expect(HotkeyWording.missingProfile("Minecraft") == "No profile named \u{201C}Minecraft\u{201D}")
    }

    /// A row says what keeps its profile action from working: a profile Karabiner-Elements doesn't list, or why no
    /// profile can be switched to. Nothing while the profiles aren't known yet, for a profile that's there, or for a
    /// hotkey without a profile action.
    @Test func aRowsProfileNote() {
        let missing = [HotkeyAction.toggle(.crosshair), .profile(.select("Speedrun"))]
        #expect(HotkeyWording.profileNote(for: missing, in: ready) == "No profile named \u{201C}Speedrun\u{201D}")
        #expect(HotkeyWording.profileNote(for: [minecraft], in: ready) == nil)
        #expect(HotkeyWording.profileNote(for: [.profile(.next)], in: ready) == nil)
        #expect(HotkeyWording.profileNote(for: [.toggle(.crosshair)], in: ready) == nil)
        #expect(HotkeyWording.profileNote(for: missing, in: .unknown) == nil)
        let notRunning = HotkeyProfiles(state: .unavailable(.notRunning), names: ["Minecraft"])
        #expect(HotkeyWording.profileNote(for: [minecraft], in: notRunning) == "Karabiner-Elements isn\u{2019}t running")
        #expect(HotkeyWording.profileNote(for: [.profile(.next)], in: notRunning) == "Karabiner-Elements isn\u{2019}t running")
        #expect(HotkeyWording.profileNote(for: [.toggle(.crosshair)], in: notRunning) == nil)
    }

    /// One problem per row: a key macOS refused comes first, since then nothing of the hotkey works.
    @Test func aRowShowsItsKeysProblemFirst() {
        let binding = HotkeyBinding(combo: f6, actions: [.profile(.select("Gone"))])
        #expect(HotkeyWording.statusNote(.registered, for: binding, profiles: ready, inList: true)
            == "No profile named \u{201C}Gone\u{201D}")
        #expect(HotkeyWording.statusNote(.conflict(.systemRefused), for: binding, profiles: ready, inList: true)
            == "macOS won\u{2019}t allow this key. Add \u{2318} or \u{2303}.")
        #expect(HotkeyWording.statusNote(.inactive, for: HotkeyBinding(combo: f6, actions: [minecraft]), profiles: ready,
                                         inList: false) == nil)
    }

    // MARK: The editors' row

    @Test func readyOffersNoneNextProfileAndEveryProfileInKarabinersOrder() {
        let choice = HotkeyProfileChoice(profiles: ready, selection: nil)
        #expect(choice.options.map(\.title) == ["None", "Next profile", "Default profile", "Minecraft", "Typing"])
        #expect(choice.options.map(\.value) == [nil, .next, .select("Default profile"), .select("Minecraft"), .select("Typing")])
        #expect(choice.note == nil)
        #expect(HotkeyProfileChoice(profiles: ready, selection: .select("Typing")) == choice)
    }

    /// A profile renamed or deleted in Karabiner-Elements stays the hotkey's choice, in view after the others, and the
    /// row says a press changes nothing.
    @Test func aChoiceKarabinerDoesntListStaysInView() {
        let choice = HotkeyProfileChoice(profiles: ready, selection: .select("Speedrun"))
        #expect(choice.options.map(\.title) == ["None", "Next profile", "Default profile", "Minecraft", "Typing", "Speedrun"])
        #expect(choice.note == "No profile named \u{201C}Speedrun\u{201D} now, so a press changes nothing.")
    }

    /// While no profile can be switched to, the row says why in place of the options, unless the hotkey has a profile
    /// action: then None and that choice stay, so it can be taken off.
    @Test func whileNoProfileCanBeSwitchedToTheRowSaysWhy() {
        for problem in [HotkeyProfiles.Problem.notInstalled, .notRunning, .versionTooOld(found: "15.0"), .configUnreadable,
                        .linkedFile, .noProfiles] {
            let profiles = HotkeyProfiles(state: .unavailable(problem), names: ["Minecraft"], current: "Minecraft")
            let empty = HotkeyProfileChoice(profiles: profiles, selection: nil)
            #expect(empty.options.isEmpty, "\(problem)")
            #expect(empty.note == HotkeyWording.profileProblem(problem) + ", so hotkeys can\u{2019}t switch profiles.")
            let kept = HotkeyProfileChoice(profiles: profiles, selection: .select("Minecraft"))
            #expect(kept.options.map(\.title) == ["None", "Minecraft"], "\(problem)")
            #expect(kept.note == empty.note)
            #expect(HotkeyProfileChoice(profiles: profiles, selection: .next).options.map(\.title) == ["None", "Next profile"])
        }
        #expect(HotkeyProfileChoice(profiles: HotkeyProfiles(state: .unavailable(.notRunning)), selection: nil).note
            == "Karabiner-Elements isn\u{2019}t running, so hotkeys can\u{2019}t switch profiles.")
    }

    @Test func untilTheProfilesAreReadTheRowSaysSo() {
        let choice = HotkeyProfileChoice(profiles: .unknown, selection: nil)
        #expect(choice.options.isEmpty)
        #expect(choice.note == "Reading Karabiner-Elements\u{2019} profiles\u{2026}")
        #expect(HotkeyProfileChoice(profiles: .unknown, selection: .next).options.map(\.title) == ["None", "Next profile"])
    }
}

/// Which profile a press goes to, and what keeps it from switching.
@Suite("Karabiner profiles for hotkeys")
struct HotkeyProfilesTests {
    @Test func nextGoesThroughKarabinersOrderAndWrapsAround() {
        let names = ["A", "B", "C"]
        #expect(HotkeyProfiles.next(after: "A", in: names) == "B")
        #expect(HotkeyProfiles.next(after: "B", in: names) == "C")
        #expect(HotkeyProfiles.next(after: "C", in: names) == "A")
        #expect(HotkeyProfiles.next(after: "Gone", in: names) == "A")
        #expect(HotkeyProfiles.next(after: nil, in: names) == "A")
        #expect(HotkeyProfiles.next(after: "A", in: ["A"]) == "A")
        #expect(HotkeyProfiles.next(after: "A", in: []) == nil)
    }

    @Test func whatKeepsAPressFromSwitching() {
        #expect(ready.issue(with: .select("Minecraft")) == nil)
        #expect(ready.issue(with: .next) == nil)
        #expect(ready.issue(with: .select("Speedrun")) == .missing("Speedrun"))
        #expect(ready.issue(with: .select("minecraft")) == .missing("minecraft"), "names are matched exactly, as Karabiner does")
        let linked = HotkeyProfiles(state: .unavailable(.linkedFile), names: ["Minecraft"])
        #expect(linked.issue(with: .select("Minecraft")) == .unavailable(.linkedFile))
        #expect(linked.issue(with: .next) == .unavailable(.linkedFile))
        #expect(HotkeyProfiles.unknown.issue(with: .select("Anything")) == nil)
    }

    @Test func onlyASwitchChangesTheProfile() {
        #expect(HotkeyProfileSwitch.switched(to: "A").changedProfile)
        for outcome in [HotkeyProfileSwitch.alreadyCurrent("A"), .onlyProfile("A"), .missing("A"), .unavailable(.notRunning),
                        .busy, .failed("A")] {
            #expect(!outcome.changedProfile, "\(outcome)")
        }
    }
}
