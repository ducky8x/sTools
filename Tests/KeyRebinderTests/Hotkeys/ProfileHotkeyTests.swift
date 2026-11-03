import Foundation
import Testing
@testable import KeyRebinder
@testable import STPlatform

/// Karabiner-Elements' command-line tool, scripted: its profiles, the one in use, which `--select-profile` changes (it
/// rewrites karabiner.json's `selected` flags, as Karabiner-Elements does), and every call. One command can be held until
/// the test lets it go: a select before it switches, anything else with its answer already read.
private final class ScriptedKarabiner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]
    private var current: String
    private var recorded: [[String]] = []
    private var held: CheckedContinuation<Void, Never>?
    private var heldCommand: String?
    let configURL: URL
    /// What `--select-profile` answers with, nil for success.
    var selectFailure: CommandResult?

    init(names: [String], current: String, configURL: URL) {
        self.names = names
        self.current = current
        self.configURL = configURL
    }

    var calls: [[String]] { lock.withLock { recorded } }
    var selects: [String] { calls.filter { $0.first == "--select-profile" }.map { $0[1] } }
    var currentProfile: String { lock.withLock { current } }

    /// The next call of `command` waits until `release()`.
    func holdNext(_ command: String) { lock.withLock { heldCommand = command } }

    var isHolding: Bool { lock.withLock { held != nil } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        waiting?.resume()
    }

    func rename(_ old: String, to new: String) {
        lock.withLock {
            names = names.map { $0 == old ? new : $0 }
            if current == old { current = new }
        }
    }

    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        let holds = lock.withLock { () -> Bool in
            recorded.append(args)
            guard args.first == heldCommand else { return false }
            heldCommand = nil
            return true
        }
        guard holds else { return answer(args) }
        if args.first == "--select-profile" {
            await hold()
            return answer(args)
        }
        let answer = answer(args)
        await hold()
        return answer
    }

    private func hold() async {
        await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
    }

    private func answer(_ args: [String]) -> CommandResult {
        lock.withLock {
            switch args.first {
            case "--version": return CommandResult(stdout: "16.3.0\n")
            case "--list-profile-names": return CommandResult(stdout: names.map { $0 + "\n" }.joined())
            case "--show-current-profile-name": return CommandResult(stdout: current + "\n")
            case "--list-connected-devices": return CommandResult(stdout: "[]")
            case "--select-profile":
                if let selectFailure { return selectFailure }
                guard names.contains(args[1]) else { return CommandResult(stdout: "`\(args[1])` is not found.\n") }
                current = args[1]
                try? Data(Self.config(names: names, selected: current).utf8).write(to: configURL)
                return CommandResult(stdout: "")
            default: return CommandResult(stdout: "", stderr: "unknown command", status: 1)
            }
        }
    }

    /// A karabiner.json with these profiles, `selected` on one; each has a rebind of its own (Caps Lock sends F13 in
    /// the first, F14 in the second, and so on), so the keys show which one is drawn.
    static func config(names: [String], selected: String) -> String {
        let profiles = names.enumerated().map { index, name in
            #"{"name": "\#(name)", "selected": \#(name == selected), "simple_modifications": [{"from": {"key_code": "caps_lock"}, "to": [{"key_code": "f\#(13 + index)"}]}]}"#
        }
        return #"{"global": {"show_in_menu_bar": true}, "profiles": [\#(profiles.joined(separator: ", "))]}"#
    }
}

private struct Grants: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// A Key Rebinder over temporary folders, with a scripted Karabiner-Elements and a hotkey list that registers through a
/// fake. Nothing touches `~/.config/karabiner`.
@MainActor
private final class ProfileRig {
    let directory: URL
    let configURL: URL
    let karabiner: ScriptedKarabiner
    let controller: KeyRebinderController
    let center: HotkeyCenter
    let registrar = FakeHotkeyRegistrar()

    /// - Parameters:
    ///   - names: Karabiner-Elements' profiles, in its order; the first is in use.
    ///   - requirement: what the status check finds: `.ready`, or the first thing missing.
    ///   - linked: karabiner.json is a symbolic link to a file beside it.
    init(names: [String] = ["Default profile", "Minecraft", "Typing"], requirement: KarabinerRequirement = .ready,
         linked: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "stools-profile-hotkeys-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = directory.appending(path: "karabiner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        configURL = folder.appending(path: "karabiner.json")
        let text = ScriptedKarabiner.config(names: names, selected: names.first ?? "")
        if linked {
            let real = directory.appending(path: "real.json")
            try Data(text.utf8).write(to: real)
            try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: real)
        } else {
            try Data(text.utf8).write(to: configURL)
        }
        karabiner = ScriptedKarabiner(names: names, current: names.first ?? "", configURL: configURL)
        let cli = KarabinerCLI(runner: karabiner, cliURL: directory.appending(path: "karabiner_cli"), fileExists: { _ in true })
        let probes = KarabinerProbes(
            appBundleExists: { requirement != .notInstalled },
            cliVersion: {
                switch requirement {
                case .notInstalled, .notRunning: nil
                case .versionTooOld(let found): found
                case .ready, .configUnreadable: "16.3.0"
                }
            },
            configReadable: { requirement != .configUnreadable })
        let settings = SettingsStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory))
        let services = ToolServices(
            settings: settings, displays: DisplayDirectory(),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource()),
            permissions: PermissionCenter(prober: Grants(), openURL: { _ in }))
        controller = KeyRebinderController(
            services: services, configURL: configURL,
            backupsDirectory: directory.appending(path: "backups", directoryHint: .isDirectory), cli: cli, probes: probes)
        settings.save(HotkeySettings(isEnabled: true))
        center = HotkeyCenter(store: settings, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        controller.connect(hotkeys: center)
    }

    /// The page opens: everything is read, the file included.
    func openPage() async {
        await controller.refresh()
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
    }

    /// The page closes and lets go of the file.
    func closePage() { controller.releaseLoadedFile() }

    isolated deinit { try? FileManager.default.removeItem(at: directory) }
}

/// A profile hotkey's press goes through the Key Rebinder (spec 6.1, 5.5.6): the same switch as the page's profile menu,
/// through Karabiner-Elements' command-line tool, with its checks read fresh each time, and nothing changes when a check
/// fails. The page's parsed karabiner.json is never brought back for it.
@MainActor
@Suite("Profile hotkeys", .serialized)
struct ProfileHotkeyTests {
    // MARK: Switching

    @Test func aPressSwitchesToTheProfileWithThePageClosed() async throws {
        let rig = try ProfileRig()
        #expect(rig.controller.config == nil && !rig.controller.hasLoadedConfig, "the page never opened")

        #expect(await rig.controller.switchProfile(for: .select("Minecraft")) == .switched(to: "Minecraft"))
        #expect(rig.karabiner.selects == ["Minecraft"])
        #expect(rig.karabiner.currentProfile == "Minecraft")
        #expect(rig.controller.currentProfile == "Minecraft")
        #expect(rig.controller.profiles == HotkeyProfiles(state: .ready, names: ["Default profile", "Minecraft", "Typing"],
                                                          current: "Minecraft"))
        #expect(rig.controller.config == nil, "the press loaded karabiner.json into memory")
    }

    @Test func nextProfileGoesInKarabinersOrderAndWrapsAround() async throws {
        let rig = try ProfileRig()
        var reached: [HotkeyProfileSwitch] = []
        for _ in 0..<4 { reached.append(await rig.controller.switchProfile(for: .next)) }
        #expect(reached == [.switched(to: "Minecraft"), .switched(to: "Typing"), .switched(to: "Default profile"),
                            .switched(to: "Minecraft")])
        #expect(rig.karabiner.selects == ["Minecraft", "Typing", "Default profile", "Minecraft"])
    }

    /// Two presses in a row switch one after the other, the second from where the first went.
    @Test func quickPressesSwitchInTurn() async throws {
        let rig = try ProfileRig()
        async let first = rig.controller.switchProfile(for: .next)
        async let second = rig.controller.switchProfile(for: .next)
        let outcomes = await [first, second]
        #expect(Set(outcomes) == [.switched(to: "Minecraft"), .switched(to: "Typing")])
        #expect(rig.karabiner.selects == ["Minecraft", "Typing"])
    }

    // MARK: Nothing changes

    /// A profile renamed or deleted in Karabiner-Elements: the press changes nothing and writes nothing, and the hotkey
    /// stays as it was set.
    @Test func aProfileThatIsGoneChangesNothing() async throws {
        let rig = try ProfileRig()
        let id = rig.center.add(combo: HotkeyFixtures.combo("f6"), actions: [.profile(.select("Minecraft"))])
        rig.karabiner.rename("Minecraft", to: "MC")
        let before = try Data(contentsOf: rig.configURL)

        #expect(await rig.controller.switchProfile(for: .select("Minecraft")) == .missing("Minecraft"))
        #expect(rig.karabiner.selects.isEmpty)
        #expect(try Data(contentsOf: rig.configURL) == before)
        #expect(rig.center.bindings.first { $0.id == id }?.actions == [.profile(.select("Minecraft"))])
        #expect(rig.controller.profiles.issue(with: .select("Minecraft")) == .missing("Minecraft"))
    }

    @Test func theProfileInUseChangesNothing() async throws {
        let rig = try ProfileRig()
        #expect(await rig.controller.switchProfile(for: .select("Default profile")) == .alreadyCurrent("Default profile"))
        let alone = try ProfileRig(names: ["Only"])
        #expect(await alone.controller.switchProfile(for: .next) == .onlyProfile("Only"))
        #expect(rig.karabiner.selects.isEmpty && alone.karabiner.selects.isEmpty)
    }

    /// While Karabiner-Elements isn't ready, or karabiner.json is a link, a press changes nothing and writes nothing.
    @Test func withoutKarabinerReadyNothingIsSwitched() async throws {
        let cases: [(KarabinerRequirement, HotkeyProfiles.Problem)] = [
            (.notInstalled, .notInstalled), (.notRunning, .notRunning),
            (.versionTooOld(found: "15.3.0"), .versionTooOld(found: "15.3.0")), (.configUnreadable, .configUnreadable),
        ]
        for (requirement, problem) in cases {
            let rig = try ProfileRig(requirement: requirement)
            #expect(await rig.controller.switchProfile(for: .select("Minecraft")) == .unavailable(problem), "\(requirement)")
            #expect(await rig.controller.switchProfile(for: .next) == .unavailable(problem), "\(requirement)")
            #expect(rig.karabiner.selects.isEmpty, "\(requirement)")
            #expect(rig.controller.profiles.state == .unavailable(problem))
        }
        let linked = try ProfileRig(linked: true)
        #expect(await linked.controller.switchProfile(for: .select("Minecraft")) == .unavailable(.linkedFile))
        #expect(linked.karabiner.selects.isEmpty)
    }

    @Test func aSwitchKarabinerRefusesSaysSo() async throws {
        let rig = try ProfileRig()
        rig.karabiner.selectFailure = CommandResult(stdout: "", stderr: "core service is not running", status: 1)
        #expect(await rig.controller.switchProfile(for: .select("Minecraft")) == .failed("Minecraft"))
        #expect(rig.controller.currentProfile == "Default profile")
    }

    /// While the page's profile menu or an edit is writing karabiner.json, a press waits for nothing and changes nothing,
    /// so the two never write at once.
    @Test func aPressWhileTheKeyRebinderWritesChangesNothing() async throws {
        let rig = try ProfileRig()
        await rig.openPage()
        rig.karabiner.holdNext("--select-profile")
        let menu = Task { await rig.controller.selectProfile("Typing") }
        #expect(await eventually { rig.karabiner.isHolding })
        #expect(rig.controller.isBusy)
        #expect(await rig.controller.switchProfile(for: .select("Minecraft")) == .busy)
        rig.karabiner.release()
        await menu.value
        #expect(rig.karabiner.selects == ["Typing"])
        #expect(rig.controller.currentProfile == "Typing")
    }

    // MARK: The page

    /// With the page open, a press reads karabiner.json again, as the profile menu does: the keys show the new profile,
    /// and the next edit writes at once, since the file Karabiner-Elements just wrote is the one it compares with.
    @Test func withThePageOpenThePressReadsTheFileAgain() async throws {
        let rig = try ProfileRig()
        await rig.openPage()
        #expect(rig.controller.binding(for: .key("caps_lock"))?.output == .key("f13"))

        #expect(await rig.controller.switchProfile(for: .select("Minecraft")) == .switched(to: "Minecraft"))
        #expect(rig.controller.config != nil)
        #expect(rig.controller.binding(for: .key("caps_lock"))?.output == .key("f14"), "the keys show the new profile")
        await rig.controller.setRebind(.key("a"), to: .key("b"))
        #expect(rig.controller.pendingEdit == nil, "the edit was held back as if someone else had changed the file")
        #expect(rig.controller.errorMessage == nil)
    }

    /// With the page closed, a press leaves the file let go: the page reads it when it opens again, with the new profile.
    @Test func withThePageClosedTheFileStaysLetGo() async throws {
        let rig = try ProfileRig()
        await rig.openPage()
        rig.closePage()
        #expect(rig.controller.config == nil && rig.controller.hasLoadedConfig)

        #expect(await rig.controller.switchProfile(for: .next) == .switched(to: "Minecraft"))
        #expect(rig.controller.config == nil, "the press brought the parsed file back")
        await rig.openPage()
        #expect(rig.controller.currentProfile == "Minecraft")
        #expect(rig.controller.binding(for: .key("caps_lock"))?.output == .key("f14"))
    }

    // MARK: What the editors read

    /// The names and the profile in use come from Karabiner-Elements' command-line tool: nothing loads karabiner.json into
    /// memory, and nothing is known before the first read.
    @Test func theProfilesAreReadWithoutLoadingTheFile() async throws {
        let rig = try ProfileRig()
        #expect(rig.controller.profiles == .unknown)
        await rig.controller.refreshProfiles()
        #expect(rig.controller.profiles == HotkeyProfiles(state: .ready, names: ["Default profile", "Minecraft", "Typing"],
                                                          current: "Default profile"))
        #expect(rig.controller.config == nil && !rig.controller.hasLoadedConfig)
        #expect((rig.center.advisor?.profiles.names ?? []) == ["Default profile", "Minecraft", "Typing"], "through the advisor")
    }

    /// A read that began before a switch and ends after it keeps the profile the switch went to, though it read the one
    /// before.
    @Test func aReadThatASwitchOverlapsDoesntPutTheOldProfileBack() async throws {
        let rig = try ProfileRig()
        await rig.openPage()
        rig.karabiner.holdNext("--show-current-profile-name")
        let read = Task { await rig.controller.refreshProfiles() }
        #expect(await eventually { rig.karabiner.isHolding })
        await rig.controller.selectProfile("Minecraft")
        rig.karabiner.release()
        await read.value
        #expect(rig.controller.currentProfile == "Minecraft")
        // The next read finds it too.
        await rig.controller.refreshProfiles()
        #expect(rig.controller.currentProfile == "Minecraft")
    }

    /// Reads that overlap share one: the rows and an editor can all ask at once.
    @Test func overlappingReadsShareOne() async throws {
        let rig = try ProfileRig()
        async let first: Void = rig.controller.refreshProfiles()
        async let second: Void = rig.controller.refreshProfiles()
        _ = await (first, second)
        #expect(rig.karabiner.calls.filter { $0 == ["--list-profile-names"] }.count == 1)
    }

    @Test func theProfilesSayWhyNoneCanBeSwitchedTo() async throws {
        for (requirement, problem) in [(KarabinerRequirement.notRunning, HotkeyProfiles.Problem.notRunning),
                                       (.configUnreadable, .configUnreadable)] {
            let rig = try ProfileRig(requirement: requirement)
            await rig.controller.refreshProfiles()
            #expect(rig.controller.profiles.state == .unavailable(problem))
        }
        let linked = try ProfileRig(linked: true)
        await linked.controller.refreshProfiles()
        #expect(linked.controller.profiles.state == .unavailable(.linkedFile))
    }

    // MARK: On the keys

    /// A hotkey whose profile isn't there wears the broken ring, and its key says why.
    @Test func aKeysHotkeyWithAProfileThatIsGoneIsMarkedBroken() async throws {
        let rig = try ProfileRig()
        await rig.openPage()
        _ = rig.center.add(combo: HotkeyFixtures.combo("f13"), actions: [.profile(.select("Speedrun"))])
        #expect(await eventually { !rig.controller.hotkeys(on: .key("caps_lock")).isEmpty })
        #expect(rig.controller.hotkeyMark(for: .key("caps_lock")) == .broken)
        #expect(rig.controller.hotkeyDescription(for: .key("caps_lock"))
            == "sTools hotkey F13: Switch to Speedrun, not working: No profile named \u{201C}Speedrun\u{201D}.")

        let shiftF13 = HotkeyFixtures.combo("f13", .shift)
        _ = rig.center.add(combo: shiftF13, actions: [.toggle(.crosshair), .profile(.select("Typing"))])
        rig.center.remove(rig.center.bindings[0].id)
        #expect(await eventually { rig.controller.hotkeys(on: .key("caps_lock")).map(\.combo) == [shiftF13] })
        #expect(rig.controller.hotkeyMark(for: .key("caps_lock")) == .working)
    }

    /// The key panel saves a profile action with the tools' actions, after them, and a second key for a profile alone
    /// asks first, as a tool's does.
    @Test func theKeyPanelSavesTheProfileAction() async throws {
        let rig = try ProfileRig()
        await rig.openPage()
        let id = try #require(rig.controller.saveHotkey(
            on: .key("f6"), editing: nil, modifiers: [], actions: [.profile(.select("Minecraft")), .toggle(.crosshair)]))
        #expect(rig.center.bindings.first { $0.id == id }?.actions == [.toggle(.crosshair), .profile(.select("Minecraft"))])

        let own = try #require(rig.controller.saveHotkey(on: .key("f7"), editing: nil, modifiers: [], actions: [.profile(.next)]))
        #expect(rig.controller.ownHotkeyReplaced(bySaving: [.profile(.next)], editing: nil)?.id == own)
        #expect(rig.controller.saveHotkey(on: .key("f8"), editing: nil, modifiers: [], actions: [.profile(.next)]) == nil)
        #expect(rig.controller.saveHotkey(on: .key("f8"), editing: nil, modifiers: [], actions: [.profile(.next)],
                                          replacingOwnHotkey: true) == own)
        #expect(rig.center.bindings.first { $0.id == own }?.combo == HotkeyFixtures.combo("f8"))
    }
}
