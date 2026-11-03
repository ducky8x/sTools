import Foundation
import KeyRebinder
import STPlatform
import Synchronization
import Testing
@testable import sTools

/// Karabiner-Elements for the harness's Key Rebinder (`Harness(karabiner:)`): its command-line tool scripted with these
/// profiles, the first in use, which `--select-profile` changes. It never runs the real tool and never touches
/// `~/.config/karabiner`.
final class HarnessKarabiner: CommandRunner, Sendable {
    private struct State {
        var names: [String]
        var current: String
        var running = true
        var selects: [String] = []
    }

    private let state: Mutex<State>

    init(profiles: [String] = ["Default profile", "Minecraft", "Typing"]) {
        state = Mutex(State(names: profiles, current: profiles.first ?? ""))
    }

    /// Whether its command-line tool answers.
    var isRunning: Bool {
        get { state.withLock { $0.running } }
        set { state.withLock { $0.running = newValue } }
    }

    /// Every profile it was asked to switch to.
    var selects: [String] { state.withLock { $0.selects } }
    var current: String { state.withLock { $0.current } }

    func rename(_ old: String, to new: String) {
        state.withLock { state in
            state.names = state.names.map { $0 == old ? new : $0 }
            if state.current == old { state.current = new }
        }
    }

    /// What the status check finds: installed, answering while `isRunning`, version 16.3.0, a file it can read.
    var probes: KarabinerProbes {
        KarabinerProbes(appBundleExists: { true }, cliVersion: { [self] in isRunning ? "16.3.0" : nil }, configReadable: { true })
    }

    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        state.withLock { state in
            guard state.running else { return CommandResult(stdout: "", stderr: "not running", status: 1) }
            switch args.first {
            case "--version": return CommandResult(stdout: "16.3.0\n")
            case "--list-profile-names": return CommandResult(stdout: state.names.map { $0 + "\n" }.joined())
            case "--show-current-profile-name": return CommandResult(stdout: state.current + "\n")
            case "--list-connected-devices": return CommandResult(stdout: "[]")
            case "--select-profile":
                state.selects.append(args[1])
                guard state.names.contains(args[1]) else { return CommandResult(stdout: "`\(args[1])` is not found.\n") }
                state.current = args[1]
                return CommandResult(stdout: "")
            default: return CommandResult(stdout: "", stderr: "unknown command", status: 1)
            }
        }
    }
}

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])

/// A profile hotkey's press in the app (spec 6.1): the app hands it to the Key Rebinder, then confirms the whole press once
/// it is done, in one line that says what changed.
@MainActor
@Suite("Profile hotkeys in the app", .serialized)
struct ProfileHotkeyAppTests {
    /// Presses the hotkey `actions` as macOS would, and waits for its confirmation.
    private func press(_ actions: [HotkeyAction], in harness: Harness) async throws -> (line: String, sealed: Bool)? {
        let id = harness.model.hotkeys.add(combo: f6, actions: actions)
        harness.model.hotkeys.isEnabled = true
        let fake = try #require(harness.hotkeyRegistrar as? FakeHotkeyRegistrar)
        let shown = harness.hotkeyHUD.presented.count
        fake.onPress?(id)
        guard await waitUntil({ harness.hotkeyHUD.presented.count > shown }) else { return nil }
        let last = try #require(harness.hotkeyHUD.presented.last)
        return (last.line, last.sealed)
    }

    @Test func aPressSwitchesTheProfileAndSaysSo() async throws {
        let karabiner = HarnessKarabiner()
        let harness = Harness(karabiner: karabiner)
        let shown = try #require(try await press([.profile(.select("Minecraft"))], in: harness))
        #expect(shown.line == "Switched to Minecraft")
        #expect(shown.sealed)
        #expect(karabiner.selects == ["Minecraft"])
        #expect(harness.model.keyRebinder?.currentProfile == "Minecraft")
        #expect(harness.hotkeyHUD.presented.count == 1, "one line for the press")
    }

    /// The tools switch at once, and the line that says so waits for the profile, so the press is confirmed once.
    @Test func toolsAndAProfileAreConfirmedInOneLine() async throws {
        let karabiner = HarnessKarabiner()
        let harness = Harness(karabiner: karabiner)
        let shown = try #require(try await press([.toggle(.crosshair), .profile(.next)], in: harness))
        #expect(harness.model.isOn(.crosshair))
        #expect(shown.line == "Crosshair on \u{00B7} Switched to Minecraft")
        #expect(shown.sealed)
        #expect(harness.hotkeyHUD.presented.count == 1)
    }

    /// A profile renamed in Karabiner-Elements: the press changes nothing, says why without the seal, and the hotkey
    /// stays as it was set.
    @Test func aProfileThatIsGoneChangesNothing() async throws {
        let karabiner = HarnessKarabiner()
        let harness = Harness(karabiner: karabiner)
        karabiner.rename("Minecraft", to: "MC")
        let shown = try #require(try await press([.profile(.select("Minecraft"))], in: harness))
        #expect(shown.line == "No profile named \u{201C}Minecraft\u{201D}")
        #expect(!shown.sealed)
        #expect(karabiner.selects.isEmpty)
        #expect(harness.model.hotkeys.bindings.last?.actions == [.profile(.select("Minecraft"))])
    }

    @Test func withoutKarabinerTheLineSaysWhy() async throws {
        let karabiner = HarnessKarabiner()
        karabiner.isRunning = false
        let harness = Harness(karabiner: karabiner)
        let shown = try #require(try await press([.toggle(.crosshair), .profile(.select("Minecraft"))], in: harness))
        #expect(shown.line == "Crosshair on \u{00B7} Karabiner-Elements isn\u{2019}t running")
        #expect(shown.sealed, "Crosshair did switch")
        #expect(karabiner.selects.isEmpty)
    }

    @Test func theProfileInUseChangesNothing() async throws {
        let harness = Harness(karabiner: HarnessKarabiner())
        let shown = try #require(try await press([.profile(.select("Default profile"))], in: harness))
        #expect(shown.line == "Already using Default profile")
        #expect(!shown.sealed)
        let alone = Harness(karabiner: HarnessKarabiner(profiles: ["Only"]))
        #expect(try await press([.profile(.next)], in: alone)?.line == "Only is the only profile")
    }

    /// Hotkeys stay as they were set: the press reads Karabiner-Elements again and rewrites nothing in the list.
    @Test func aPressNeverChangesTheHotkeys() async throws {
        let karabiner = HarnessKarabiner()
        let harness = Harness(karabiner: karabiner)
        karabiner.rename("Typing", to: "Text")
        _ = try await press([.profile(.select("Typing"))], in: harness)
        await harness.model.settings.flush()
        let stored = harness.store.load(HotkeySettings.self)
        #expect(stored.bindings.map(\.actions) == [[.profile(.select("Typing"))]])
    }
}

/// The confirmation's words for a profile hotkey (spec 6.1).
@Suite("Hotkey confirmation for profiles")
struct ProfileConfirmationTests {
    @Test func eachOutcomeInOneLine() {
        #expect(HotkeyConfirmation.phrase(.profile(.switched(to: "Minecraft"))) == "Switched to Minecraft")
        #expect(HotkeyConfirmation.phrase(.profile(.alreadyCurrent("Minecraft"))) == "Already using Minecraft")
        #expect(HotkeyConfirmation.phrase(.profile(.onlyProfile("Minecraft"))) == "Minecraft is the only profile")
        #expect(HotkeyConfirmation.phrase(.profile(.missing("Minecraft"))) == "No profile named \u{201C}Minecraft\u{201D}")
        #expect(HotkeyConfirmation.phrase(.profile(.unavailable(.notInstalled))) == "Karabiner-Elements isn\u{2019}t installed")
        #expect(HotkeyConfirmation.phrase(.profile(.unavailable(.linkedFile))) == "karabiner.json is a symbolic link")
        #expect(HotkeyConfirmation.phrase(.profile(.busy)) == "The Key Rebinder is saving, so the profile stays")
        #expect(HotkeyConfirmation.phrase(.profile(.failed("Minecraft"))) == "Couldn\u{2019}t switch to Minecraft")
    }

    @Test func onlyASwitchEarnsTheSeal() {
        #expect(HotkeyConfirmation.changedSomething([.profile(.switched(to: "A"))]))
        for outcome in [HotkeyProfileSwitch.alreadyCurrent("A"), .onlyProfile("A"), .missing("A"), .unavailable(.notRunning),
                        .busy, .failed("A")] {
            #expect(!HotkeyConfirmation.changedSomething([.profile(outcome)]), "\(outcome)")
        }
        #expect(HotkeyConfirmation.changedSomething([.tool(.crosshair, isOn: true), .profile(.missing("A"))]))
    }
}
