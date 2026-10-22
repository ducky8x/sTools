import Foundation
import Testing
@testable import KeyRebinder
@testable import STPlatform

/// Answers each `karabiner_cli` command by its first argument and records every call.
private final class RoutingCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: CommandResult]
    private var recorded: [[String]] = []

    init(_ answers: [String: CommandResult]) { self.answers = answers }

    var calls: [[String]] { lock.withLock { recorded } }

    func set(_ command: String, _ stdout: String) { lock.withLock { answers[command] = CommandResult(stdout: stdout) } }

    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        lock.withLock {
            recorded.append(args)
            return answers[args.first ?? ""] ?? CommandResult(stdout: "", stderr: "unknown command", status: 1)
        }
    }
}

private struct AlwaysGranted: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

private let twoProfiles = """
{
  "global": { "show_in_menu_bar": true },
  "profiles": [
    { "name": "Default profile", "selected": true,
      "simple_modifications": [{ "from": { "key_code": "left_alt" }, "to": [{ "key_code": "left_command" }] }] },
    { "name": "Speedrun", "simple_modifications": [] }
  ]
}
"""

@MainActor
private struct Harness {
    let directory: URL
    let configURL: URL
    let runner: RoutingCommandRunner
    let controller: KeyRebinderController
    let registrar: FakeHotkeyRegistrar
    /// The hotkey list the controller is connected to, when built `hotkeys: true`.
    let center: HotkeyCenter?

    /// - Parameters:
    ///   - config: the starting `karabiner.json`; nil writes none.
    ///   - hotkeys: connects a real `HotkeyCenter` over the same settings folder, registering through a fake.
    init(config: String? = twoProfiles, ready: Bool = true, symlink: Bool = false, hotkeys: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "stools-rebinder-\(UUID().uuidString)", directoryHint: .isDirectory)
        let karabiner = directory.appending(path: "karabiner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: karabiner, withIntermediateDirectories: true)
        configURL = karabiner.appending(path: "karabiner.json")
        if symlink, let config {
            let real = directory.appending(path: "real.json")
            try Data(config.utf8).write(to: real)
            try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: real)
        } else if let config {
            try Data(config.utf8).write(to: configURL)
        }
        runner = RoutingCommandRunner([
            "--version": CommandResult(stdout: "16.3.0\n"),
            "--list-profile-names": CommandResult(stdout: "Default profile\nSpeedrun\n"),
            "--show-current-profile-name": CommandResult(stdout: "Default profile\n"),
            "--list-connected-devices": CommandResult(stdout: ConnectedDeviceTests.sample),
            "--select-profile": CommandResult(stdout: ""),
        ])
        let cli = KarabinerCLI(runner: runner, cliURL: URL(fileURLWithPath: "/fake/karabiner_cli"), fileExists: { _ in true })
        let probes = KarabinerProbes(
            appBundleExists: { true }, cliVersion: { ready ? "16.3.0" : nil }, configReadable: { true })
        let settings = SettingsStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory))
        let services = ToolServices(
            settings: settings,
            displays: DisplayDirectory(),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource()),
            permissions: PermissionCenter(prober: AlwaysGranted()))
        controller = KeyRebinderController(
            services: services, configURL: configURL,
            backupsDirectory: directory.appending(path: "backups", directoryHint: .isDirectory), cli: cli, probes: probes)
        registrar = FakeHotkeyRegistrar()
        if hotkeys {
            // An existing, empty list, rather than a new install's ⌘1–⌘5.
            settings.save(HotkeySettings())
            let center = HotkeyCenter(store: settings, registrar: registrar, toolStates: { [:] }, handler: { _ in })
            controller.connect(hotkeys: center)
            self.center = center
        } else {
            center = nil
        }
    }

    func onDisk() throws -> JSONValue { try JSONValue.parse(data: Data(contentsOf: configURL)) }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Key Rebinder controller", .serialized) @MainActor
struct KeyRebinderControllerTests {
    @Test func refreshLoadsStatusProfilesAndDevices() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        await harness.controller.refresh()
        let controller = harness.controller
        #expect(controller.requirement == .ready)
        #expect(controller.karabinerVersion == "16.3.0")
        #expect(controller.profileNames == ["Default profile", "Speedrun"])
        #expect(controller.currentProfile == "Default profile")
        #expect(controller.devices.count == 2)
        #expect(controller.canEdit)
        #expect(controller.diagnosticsSummary == "Ready, Karabiner-Elements 16.3.0")
    }

    @Test func aRebindIsWrittenThroughTheStore() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        await harness.controller.refresh()
        await harness.controller.setRebind(.key("caps_lock"), to: .key("escape"))
        #expect(harness.controller.errorMessage == nil)
        let rebinds = RebindEditor.rebinds(in: try harness.onDisk(), profile: "Default profile")
        #expect(rebinds.map(\.from).contains(.key("caps_lock")))
        #expect(harness.controller.binding(for: .key("caps_lock"))?.output == .key("escape"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: harness.directory.appending(path: "backups").path)
        #expect(backups.count == 1)
    }

    @Test func editingAKeyReusesTheNameItsRebindAlreadyHas() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        await harness.controller.refresh()
        #expect(harness.controller.source(for: .key("left_option")) == .key("left_alt"))
        #expect(harness.controller.binding(for: .key("left_option"))?.output == .key("left_command"))
        await harness.controller.setRebind(.key("left_option"), to: .key("left_control"))
        let rebinds = RebindEditor.rebinds(in: try harness.onDisk(), profile: "Default profile", includeOverridden: true)
        #expect(rebinds.map(\.from) == [.key("left_alt")])
        #expect(rebinds.map(\.to) == [.key("left_control")])
        await harness.controller.removeRebind(.key("left_option"))
        #expect(RebindEditor.rebinds(in: try harness.onDisk(), profile: "Default profile").isEmpty)
    }

    @Test func withoutKarabinerRunningTheDiagramWorksButEditingIsOff() async throws {
        let harness = try Harness(ready: false)
        defer { harness.remove() }
        await harness.controller.refresh()
        let controller = harness.controller
        #expect(controller.requirement == .notRunning)
        #expect(controller.config != nil)
        #expect(controller.currentProfile == "Default profile")
        #expect(controller.binding(for: .key("left_option"))?.output == .key("left_command"))
        #expect(!controller.canEdit)
        let before = try Data(contentsOf: harness.configURL)
        await controller.setRebind(.key("a"), to: .key("b"))
        #expect(try Data(contentsOf: harness.configURL) == before)
        #expect(controller.devices.isEmpty)
    }

    @Test func aSymbolicLinkIsReadButNeverWritten() async throws {
        let harness = try Harness(symlink: true)
        defer { harness.remove() }
        await harness.controller.refresh()
        #expect(harness.controller.config != nil)
        #expect(harness.controller.configIsSymbolicLink)
        #expect(!harness.controller.canEdit)
    }

    @Test func anOutsideChangeIsPreviewedThenConfirmed() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        await controller.refresh()
        // Someone else edits the file after sTools read it.
        let outside = try RebindEditor.setRebind(in: try harness.onDisk(), profile: "Default profile", from: .key("q"), to: .key("w"))
        try Data(outside.serialized().utf8).write(to: harness.configURL)

        await controller.setRebind(.key("caps_lock"), to: .key("escape"))
        let pending = try #require(controller.pendingEdit)
        #expect(RebindEditor.rebinds(in: pending.preview.root, profile: "Default profile").map(\.from).contains(.key("q")))
        #expect(RebindEditor.rebinds(in: try harness.onDisk(), profile: "Default profile").map(\.from).contains(.key("caps_lock")) == false)

        await controller.confirmPendingEdit()
        #expect(controller.pendingEdit == nil)
        let froms = RebindEditor.rebinds(in: try harness.onDisk(), profile: "Default profile").map(\.from)
        #expect(froms.contains(.key("q")) && froms.contains(.key("caps_lock")))
    }

    @Test func discardingAPreviewShowsTheFileAsItIs() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        await controller.refresh()
        let outside = try RebindEditor.setRebind(in: try harness.onDisk(), profile: "Default profile", from: .key("q"), to: .key("w"))
        try Data(outside.serialized().utf8).write(to: harness.configURL)
        await controller.setRebind(.key("caps_lock"), to: .key("escape"))
        #expect(controller.pendingEdit != nil)
        await controller.discardPendingEdit()
        #expect(controller.pendingEdit == nil)
        #expect(controller.binding(for: .key("q"))?.output == .key("w"))
        #expect(controller.binding(for: .key("caps_lock")) == nil)
    }

    @Test func profilesAreSwitchedThroughTheCLIAndEditedThroughTheStore() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        await controller.refresh()
        await controller.selectProfile("Speedrun")
        #expect(harness.runner.calls.contains(["--select-profile", "Speedrun"]))
        #expect(controller.currentProfile == "Speedrun")

        await controller.createProfile(named: controller.suggestedNewProfileName(), duplicatingCurrent: false)
        #expect(RebindEditor.profileNames(in: try harness.onDisk()) == ["Default profile", "Speedrun", "Untitled Profile"])
        await controller.renameProfile("Speedrun", to: "Any%")
        #expect(controller.currentProfile == "Any%")
        await controller.moveProfile(from: 2, to: 0)
        #expect(RebindEditor.profileNames(in: try harness.onDisk()) == ["Untitled Profile", "Default profile", "Any%"])
        await controller.deleteProfile("Untitled Profile")
        #expect(RebindEditor.profileNames(in: try harness.onDisk()) == ["Default profile", "Any%"])
    }

    @Test func findingsNeedALayoutAndFollowTheCheckerSettings() async throws {
        let config = """
        { "profiles": [{ "name": "P", "selected": true, "simple_modifications": [
            { "from": { "key_code": "caps_lock" }, "to": [{ "key_code": "left_control" }] } ] }] }
        """
        let harness = try Harness(config: config)
        defer { harness.remove() }
        let controller = harness.controller
        harness.runner.set("--list-profile-names", "P\n")
        harness.runner.set("--show-current-profile-name", "P\n")
        await controller.refresh()
        #expect(controller.derived.findings.isEmpty)
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        #expect(controller.derived.findings.map(\.kind) == [.oneKeyOneInput])
        #expect(controller.derived.flaggedKeys.contains(.key("caps_lock")))
        #expect(controller.findings(for: .key("left_control")).count == 1)
        controller.settings.checkerIncludesSpeedrunRules = false
        #expect(controller.derived.findings.isEmpty)
        controller.settings.checkerIncludesSpeedrunRules = true
        #expect(!controller.derived.findings.isEmpty)
        controller.settings.checkerEnabled = false
        #expect(controller.derived.findings.isEmpty)
        #expect(controller.derived.flaggedKeys.isEmpty)
        #expect(controller.findings(for: .key("left_control")).isEmpty)
    }

    @Test func minecraftKeybindsComeFromTheChosenFile() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let options = harness.directory.appending(path: "options.txt")
        try Data("key_key.sprint:key.keyboard.left.control\nkey_key.attack:key.mouse.left\n".utf8).write(to: options)
        let controller = harness.controller
        controller.settings.customOptionsFilePath = options.path
        #expect(controller.optionsFile == options)
        #expect(controller.minecraftActions(for: .key("left_control")) == ["Sprint"])
        controller.settings.showsMinecraftKeybinds = false
        #expect(controller.minecraftKeybinds == nil)
        #expect(controller.minecraftActions(for: .key("left_control")).isEmpty)
    }

    @Test func aMissingOptionsFileIsExplained() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        harness.controller.settings.customOptionsFilePath = harness.directory.appending(path: "nope.txt").path
        #expect(harness.controller.minecraftKeybinds == nil)
        #expect(harness.controller.optionsProblem?.contains("could not read") == true)
    }

    @Test func theTesterLightsKeysOnlyWhileOn() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        await controller.refresh()
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        controller.testerPressed(.key("a"))
        #expect(controller.litKeys.isEmpty)
        controller.isTesting = true
        controller.testerPressed(.key("left_command"))
        #expect(controller.litKeys == [.key("left_command")])
        #expect(controller.lastTrace?.sources == [.key("left_option"), .key("left_command")])
        controller.testerReleased(.key("left_command"))
        #expect(controller.litKeys.isEmpty)
        controller.isTesting = false
        #expect(controller.lastTrace == nil)
    }

    @Test func aPressedKeyResolvesToItsOnePhysicalSource() async throws {
        let harness = try Harness(config: """
            { "profiles": [{ "name": "P", "selected": true, "simple_modifications": [
                { "from": { "key_code": "caps_lock" }, "to": [{ "key_code": "f13" }] } ] }] }
            """)
        defer { harness.remove() }
        harness.runner.set("--list-profile-names", "P\n")
        harness.runner.set("--show-current-profile-name", "P\n")
        await harness.controller.refresh()
        harness.controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        #expect(harness.controller.physicalKey(forArrived: .key("f13")) == .key("caps_lock"))
        #expect(harness.controller.physicalKey(forArrived: .key("a")) == .key("a"))
    }
}

@Suite("Key Rebinder key presses", .serialized) @MainActor
struct KeyRebinderPressTests {
    @Test func pressingAKeySelectsItsPhysicalKey() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        await harness.controller.refresh()
        let controller = harness.controller
        #expect(!controller.handle(.down(.key("a"), isRepeat: false), commandHeld: false, isBusy: false))
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        #expect(controller.handle(.down(.key("a"), isRepeat: false), commandHeld: false, isBusy: false))
        #expect(controller.selectedKey == .key("a"))
        // Left Option is rebound to Left Command, so a Left Command press could be either key: it is kept as is.
        #expect(controller.handle(.down(.key("left_command"), isRepeat: false), commandHeld: false, isBusy: false))
        #expect(controller.selectedKey == .key("left_command"))
    }

    @Test func shortcutsTypingAndRepeatsAreLeftAlone() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        #expect(!controller.handle(.down(.key("q"), isRepeat: false), commandHeld: true, isBusy: false))
        #expect(!controller.handle(.down(.key("q"), isRepeat: false), commandHeld: false, isBusy: true))
        #expect(!controller.handle(.down(.key("q"), isRepeat: true), commandHeld: false, isBusy: false))
        #expect(!controller.handle(.down(.pointing("button1"), isRepeat: false), commandHeld: false, isBusy: false))
        #expect(controller.selectedKey == nil)
    }

    @Test func captureTakesKeysAndExtraButtonsButNotClicks() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        controller.isCapturingOutput = true
        #expect(!controller.handle(.down(.pointing("button1"), isRepeat: false), commandHeld: false, isBusy: false))
        #expect(controller.isCapturingOutput)
        #expect(controller.handle(.down(.pointing("button4"), isRepeat: false), commandHeld: false, isBusy: false))
        #expect(controller.capturedOutput == .pointing("button4"))
        #expect(!controller.isCapturingOutput)
        #expect(controller.selectedKey == nil)
    }

    /// With keyboard navigation on (Full Keyboard Access), Tab, Shift-Tab and Space move focus and press the focused
    /// control, as everywhere in sTools, instead of selecting their keys; Test keys and Press… still take them.
    @Test func keyboardNavigationKeepsTabShiftAndSpace() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        func leaves(_ press: KeyPress, navigation: Bool = true) -> Bool {
            KeyRebinderView.leavesToKeyboardNavigation(press, keyboardNavigation: navigation, controller: controller)
        }
        for code in ["tab", "spacebar", "left_shift", "right_shift"] {
            let press = KeyPress.down(.key(code), isRepeat: false)
            #expect(leaves(press))
            #expect(leaves(.up(.key(code))))
            #expect(!leaves(press, navigation: false))
            // The page passes the press on as busy, so it isn't used and the window gets it.
            #expect(!controller.handle(press, commandHeld: false, isBusy: leaves(press)))
        }
        #expect(controller.selectedKey == nil)
        for code in ["a", "return_or_enter", "escape", "left_arrow", "left_control"] {
            #expect(!leaves(.down(.key(code), isRepeat: false)))
        }
        let a = KeyPress.down(.key("a"), isRepeat: false)
        #expect(controller.handle(a, commandHeld: false, isBusy: leaves(a)))
        #expect(controller.selectedKey == .key("a"))
        // Without keyboard navigation, pressing Tab selects it as before.
        let tab = KeyPress.down(.key("tab"), isRepeat: false)
        #expect(controller.handle(tab, commandHeld: false, isBusy: leaves(tab, navigation: false)))
        #expect(controller.selectedKey == .key("tab"))

        controller.isTesting = true
        #expect(!leaves(tab))
        controller.isTesting = false
        controller.isCapturingOutput = true
        #expect(!leaves(.down(.key("spacebar"), isRepeat: false)))
    }

    @Test func theTesterSeesEverythingButOnlySwallowsPlainKeys() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let controller = harness.controller
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        controller.isTesting = true
        #expect(controller.handle(.down(.key("w"), isRepeat: false), commandHeld: false, isBusy: false))
        #expect(controller.litKeys == [.key("w")])
        #expect(!controller.handle(.down(.pointing("button1"), isRepeat: false), commandHeld: false, isBusy: false))
        #expect(controller.litKeys == [.key("w"), .pointing("button1")])
        #expect(!controller.handle(.down(.key("tab"), isRepeat: false), commandHeld: true, isBusy: false))
        #expect(controller.handle(.up(.key("w")), commandHeld: false, isBusy: false))
        #expect(!controller.litKeys.contains(.key("w")))
        #expect(controller.selectedKey == nil)
    }
}

/// Profile "P": Caps Lock sends F13.
private let capsToF13 = """
{ "profiles": [{ "name": "P", "selected": true, "simple_modifications": [
    { "from": { "key_code": "caps_lock" }, "to": [{ "key_code": "f13" }] } ] }] }
"""

/// Profile "P" with these key-to-key rebinds, raw Simple Modifications and rules.
private func profileP(_ pairs: [(String, String)] = [], simple: [String] = [], rules: [String] = []) -> String {
    HotkeyFixtures.config(pairs, simple: simple, rules: rules).serialized()
}

@Suite("Key Rebinder hotkeys", .serialized) @MainActor
struct KeyRebinderHotkeyTests {
    /// Profile "P" from `config`, Karabiner `ready` or not, hotkeys on and an ANSI keyboard chosen.
    private func make(
        _ config: String? = capsToF13, ready: Bool = true, formFactor: KeyboardFormFactor = .laptop
    ) async throws -> Harness {
        let harness = try Harness(config: config, ready: ready, hotkeys: true)
        harness.runner.set("--list-profile-names", "P\n")
        harness.runner.set("--show-current-profile-name", "P\n")
        await harness.controller.refresh()
        harness.controller.chooseLayout(shape: .ansi, formFactor: formFactor)
        harness.center?.isEnabled = true
        return harness
    }

    // MARK: Connecting and showing

    @Test func connectingMakesTheControllerTheListsAdvisor() throws {
        let harness = try Harness(hotkeys: true)
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        #expect(center.advisor === controller)
        #expect(controller.hotkeyCenter === center)
        #expect(controller.showsHotkeyLayer)
        #expect(!controller.hotkeysAreOn)
        controller.turnHotkeysOn()
        #expect(center.isEnabled && controller.hotkeysAreOn)
        controller.settings.showsHotkeys = false
        #expect(!controller.showsHotkeyLayer)

        let unconnected = try Harness()
        defer { unconnected.remove() }
        #expect(unconnected.controller.hotkeyCenter == nil)
        #expect(!unconnected.controller.showsHotkeyLayer)
    }

    @Test func aHotkeyAddedThroughTheListShowsOnTheKeyThatSendsIt() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        let id = center.add(combo: HotkeyFixtures.combo("f13", .option), actions: [.toggle(.crosshair)])
        #expect(await eventually { controller.hotkeys(on: .key("caps_lock")).map(\.id) == [id] })
        #expect(controller.hotkeyMark(for: .key("caps_lock")) == .working)
        #expect(controller.hotkeyMark(for: .key("a")) == nil)
        #expect(controller.hotkeyDescription(for: .key("caps_lock")) == "sTools hotkey Option F13: Crosshair.")
        #expect(controller.hotkeyTarget(for: .key("caps_lock")) == .key(sends: .key("f13"), keyCode: 105))
    }

    @Test func aKeyWithABrokenHotkeyWearsTheBrokenMark() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        harness.registrar.refused = [HotkeyFixtures.combo("f13", .option)]
        center.add(combo: HotkeyFixtures.combo("f13"), actions: [.toggle(.crosshair)])
        center.add(combo: HotkeyFixtures.combo("f13", .option), actions: [.startStopRecording])
        #expect(await eventually { controller.hotkeys(on: .key("caps_lock")).count == 2 })
        #expect(controller.hotkeyMark(for: .key("caps_lock")) == .broken)
        #expect(controller.hotkeyDescription(for: .key("caps_lock"))
            == "sTools hotkeys: F13, Crosshair; Option F13, Screen Recording, not working: Refused by macOS. Some versions need \u{2318} or \u{2303}.")
    }

    // MARK: Editing

    @Test func saveHotkeyStoresWhatTheKeySendsWithTheChosenModifiersAndActions() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let id = try #require(harness.controller.saveHotkey(
            on: .key("caps_lock"), editing: nil, modifiers: [.shift, .option],
            actions: [.startStopRecording, .toggle(.crosshair), .toggle(.nbbOverlay)]))
        let saved = try #require(center.bindings.first { $0.id == id })
        #expect(saved.combo == HotkeyCombo(keyCode: 105, modifiers: [.option, .shift]))
        #expect(saved.actions == [.toggle(.nbbOverlay), .toggle(.crosshair), .startStopRecording])
    }

    @Test func editingKeepsTheIdAndDeletingRemovesTheHotkey() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        let id = try #require(controller.saveHotkey(on: .key("caps_lock"), editing: nil, modifiers: [], actions: [.toggle(.crosshair)]))
        let edited = controller.saveHotkey(on: .key("caps_lock"), editing: id, modifiers: .control, actions: [.toggle(.windowBackdrop)])
        #expect(edited == id)
        #expect(center.bindings.map(\.id) == [id])
        #expect(center.bindings.first?.combo == HotkeyFixtures.combo("f13", .control))
        #expect(center.bindings.first?.actions == [.toggle(.windowBackdrop)])
        // Saving it unchanged isn't a duplicate of itself.
        #expect(controller.saveHotkey(on: .key("caps_lock"), editing: id, modifiers: .control, actions: [.toggle(.windowBackdrop)]) == id)
        controller.deleteHotkey(id)
        #expect(center.bindings.isEmpty)
    }

    @Test func saveHotkeyRefusesWhatCantBeAHotkey() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        let first = controller.saveHotkey(on: .key("caps_lock"), editing: nil, modifiers: [], actions: [.toggle(.crosshair)])
        #expect(first != nil)
        #expect(controller.saveHotkey(on: .key("left_shift"), editing: nil, modifiers: [], actions: [.toggle(.crosshair)]) == nil)
        #expect(controller.saveHotkey(on: .key("caps_lock"), editing: nil, modifiers: [], actions: [.toggle(.nbbOverlay)]) == nil)
        #expect(controller.saveHotkey(on: .key("q"), editing: nil, modifiers: .command, actions: [.toggle(.crosshair)]) == nil)
        #expect(controller.saveHotkey(on: .key("caps_lock"), editing: nil, modifiers: .shift, actions: []) == nil)
        #expect(center.bindings.count == 1)
    }

    @Test func hotkeysCanBeEditedWithoutKarabinerReady() async throws {
        let harness = try await make(ready: false)
        defer { harness.remove() }
        #expect(!harness.controller.canEdit)
        let id = harness.controller.saveHotkey(on: .key("caps_lock"), editing: nil, modifiers: [], actions: [.toggle(.crosshair)])
        #expect(id != nil)
        #expect(harness.center?.bindings.first?.combo == HotkeyFixtures.combo("f13"))
    }

    // MARK: What shows

    /// Every hotkey shows on its key while hotkeys are on, Test keys' pause included; while they're off, the line
    /// under the plate says why no key is marked and offers Turn On. Show hotkeys is on by default.
    @Test func everyHotkeyShowsOnItsKeyAndTheOffLineSaysWhyNot() async throws {
        #expect(KeyRebinderSettings().showsHotkeys)
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        let id = center.add(combo: HotkeyFixtures.combo("u", [.shift, .command]), actions: [.toggle(.crosshair)])
        #expect(await eventually { controller.hotkeys(on: .key("u")).map(\.id) == [id] })
        #expect(controller.hotkeyMark(for: .key("u")) == .working)
        #expect(controller.hotkeyDescription(for: .key("u"))?.hasSuffix(": Crosshair.") == true)
        #expect(controller.hotkeysOffText == nil)

        controller.isTesting = true
        #expect(center.isPaused)
        #expect(controller.hotkeyMark(for: .key("u")) == .working)
        controller.isTesting = false

        center.isEnabled = false
        #expect(await eventually { controller.derived.hotkeysByKey.isEmpty })
        #expect(controller.hotkeysOffText == "sTools hotkeys are off, so their keys aren\u{2019}t marked: \u{21E7}\u{2318}U (Crosshair).")
        controller.turnHotkeysOn()
        #expect(await eventually { controller.hotkeyMark(for: .key("u")) == .working })
        #expect(controller.hotkeysOffText == nil)
    }

    @Test func withTheMasterSwitchOffNothingShows() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        center.add(combo: HotkeyFixtures.combo("f3"), actions: [.toggle(.crosshair)])
        center.add(combo: HotkeyFixtures.combo("f20"), actions: [.toggle(.nbbOverlay)])
        #expect(await eventually { !controller.derived.hotkeyFindings.isEmpty && !controller.derived.unplacedHotkeys.isEmpty })
        #expect(controller.hotkeyMark(for: .key("f3")) == .working)
        #expect(controller.unplacedHotkeysText == "Hotkeys no key here sends: F20 (NBB Overlay).")

        center.isEnabled = false
        #expect(await eventually { controller.derived.hotkeyFindings.isEmpty })
        #expect(controller.derived.unplacedHotkeys.isEmpty)
        #expect(controller.derived.hotkeysByKey.isEmpty)
        #expect(controller.hotkeyMark(for: .key("f3")) == nil)
        #expect(controller.unplacedHotkeysText == nil)
        #expect(controller.rebindHotkeyNotes(for: .key("a"), becoming: .key("f20")).isEmpty)
    }

    @Test func aRefusedHotkeyTakesNoGameKeyAndDoesNotSkipAOneKeyOneInputFinding() async throws {
        let harness = try await make(profileP([("caps_lock", "f18"), ("right_option", "f18")]))
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        // Minecraft binds no modifier key, so an accepted bare F18 hotkey always fires and the game never gets F18.
        let options = harness.directory.appending(path: "options.txt")
        try Data("key_key.hotbar.1:key.keyboard.f18\n".utf8).write(to: options)
        controller.settings.customOptionsFilePath = options.path
        #expect(controller.minecraftKeybinds != nil)
        harness.registrar.refused = [HotkeyFixtures.combo("f18"), HotkeyFixtures.combo("f3")]
        let f18 = center.add(combo: HotkeyFixtures.combo("f18"), actions: [.toggle(.crosshair)])
        center.add(combo: HotkeyFixtures.combo("f3"), actions: [.toggle(.crosshair)])
        center.add(combo: HotkeyFixtures.combo("f20"), actions: [.toggle(.crosshair)])
        #expect(await eventually { controller.derived.unplacedHotkeys.count == 1 })
        #expect(controller.derived.hotkeyFindings.isEmpty)
        #expect(controller.derived.findings.contains { $0.kind == .oneKeyOneInput && $0.message.contains("both produce F18") })
        #expect(controller.hotkeyMark(for: .key("caps_lock")) == .broken)

        // Retried on the next change, and accepted this time: the game never gets F18 now.
        harness.registrar.refused = []
        center.update(f18, actions: [.toggle(.nbbOverlay)])
        #expect(await eventually { !controller.derived.findings.contains { $0.kind == .oneKeyOneInput } })
        #expect(controller.hotkeyMark(for: .key("caps_lock")) == .working)

        // Once Minecraft sneaks on Shift, the hotkey doesn't fire while Shift is held, so the game gets F18 again.
        try Data("key_key.sneak:key.keyboard.left.shift\nkey_key.hotbar.1:key.keyboard.f18\n".utf8).write(to: options)
        controller.loadMinecraftKeybinds()
        controller.recompute()
        #expect(controller.derived.findings.contains { $0.kind == .oneKeyOneInput && $0.message.contains("both produce F18") })
    }

    @Test func hotkeyFindingsNeedNoKarabinerFile() async throws {
        let harness = try await make(nil)
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        #expect(controller.config == nil)
        center.add(combo: HotkeyFixtures.combo("f3"), actions: [.toggle(.crosshair)])
        #expect(await eventually { controller.derived.hotkeyFindings.count == 1 })
        let finding = try #require(controller.derived.hotkeyFindings.first)
        #expect(finding.keys == [.key("f3")])
        #expect(finding.message == "The sTools hotkey F3 (Crosshair) keeps F3 from Minecraft, which uses it for Debug screen.")
        #expect(controller.hotkeyFindings(for: .key("f3")) == [finding])
        #expect(controller.findings(for: .key("f3")).isEmpty)
        #expect(controller.derived.hotkeyFlaggedKeys.contains(.key("f3")))
        #expect(controller.hotkeyMark(for: .key("f3")) == .working)

        controller.settings.checkerIncludesSpeedrunRules = false
        #expect(controller.derived.hotkeyFindings == [finding])
        controller.settings.checkerEnabled = false
        #expect(controller.derived.hotkeyFindings.isEmpty)
        #expect(controller.derived.hotkeyFlaggedKeys.isEmpty)
        controller.settings.checkerEnabled = true
        controller.settings.showsHotkeys = false
        #expect(controller.derived.hotkeyFindings.isEmpty)
        #expect(controller.derived.hotkeysByKey.isEmpty)
    }

    // MARK: Use F20

    @Test func useF20IsOfferedOnAKeyThatCantCarryHotkeys() async throws {
        let harness = try await make(profileP())
        defer { harness.remove() }
        let controller = harness.controller
        #expect(controller.canEdit)
        #expect(controller.spareKeyOffer(for: .key("caps_lock")) == .key("f20"))
        #expect(controller.hotkeyUnavailableText(for: .key("caps_lock")) == "macOS can\u{2019}t use Caps Lock alone as a hotkey.")
        #expect(controller.spareKeyOffer(for: .pointing("button4")) == .key("f20"))
        #expect(controller.hotkeyUnavailableText(for: .pointing("button4")) == "Mouse buttons can\u{2019}t be hotkeys.")
        // A key that can carry hotkeys needs none.
        #expect(controller.spareKeyOffer(for: .key("a")) == nil)
        #expect(controller.hotkeyUnavailableText(for: .key("a")) == nil)
    }

    @Test func useF20IsHeldBackWhereItWouldDoHarm() async throws {
        let harness = try await make(profileP(rules: [HotkeyFixtures.tapHoldRule("caps_lock", held: "left_control", alone: "escape")]))
        defer { harness.remove() }
        let controller = harness.controller
        for button in ["button1", "button2"] {
            #expect(controller.spareKeyOffer(for: .pointing(button)) == nil)
            #expect(controller.hotkeyUnavailableText(for: .pointing(button)) == "Left and right click can\u{2019}t be hotkeys.")
        }
        #expect(controller.spareKeyOffer(for: .key("caps_lock")) == nil)
        #expect(controller.hotkeyUnavailableText(for: .key("caps_lock"))
            == "A rule drives Caps Lock, so sTools can\u{2019}t tell which key apps get. Add its hotkey in Home by pressing the key.")
        // Minecraft sneaks on Left Shift by default.
        #expect(controller.spareKeyOffer(for: .key("left_shift")) == nil)
        #expect(controller.hotkeyUnavailableText(for: .key("left_shift"))
            == "macOS can\u{2019}t use Left Shift alone as a hotkey. Minecraft uses it for Sneak by default.")

        // And by options.txt.
        let options = harness.directory.appending(path: "options.txt")
        try Data(HotkeyFixtures.options1161Text.utf8).write(to: options)
        controller.settings.customOptionsFilePath = options.path
        #expect(controller.minecraftKeybinds != nil)
        #expect(controller.spareKeyOffer(for: .key("left_shift")) == nil)
        #expect(controller.hotkeyUnavailableText(for: .key("left_shift")) == "macOS can\u{2019}t use Left Shift alone as a hotkey. Minecraft uses it for Sneak.")
        #expect(controller.spareKeyOffer(for: .key("right_shift")) == .key("f20"))
    }

    @Test func useF20NeedsKarabinerReadyAndNoChangeWaiting() async throws {
        let notReady = try await make(profileP(), ready: false)
        defer { notReady.remove() }
        #expect(notReady.controller.spareKeyOffer(for: .key("caps_lock")) == nil)
        #expect(notReady.controller.hotkeyUnavailableText(for: .key("caps_lock")) == "macOS can\u{2019}t use Caps Lock alone as a hotkey.")

        let harness = try await make(profileP())
        defer { harness.remove() }
        let controller = harness.controller
        let outside = try RebindEditor.setRebind(in: try harness.onDisk(), profile: "P", from: .key("q"), to: .key("w"))
        try Data(outside.serialized().utf8).write(to: harness.configURL)
        await controller.setRebind(.key("e"), to: .key("r"))
        #expect(controller.pendingEdit != nil)
        #expect(controller.spareKeyOffer(for: .key("caps_lock")) == nil)
    }

    @Test func askingAboutTheSpareKeyWritesNothing() async throws {
        let harness = try await make(profileP())
        defer { harness.remove() }
        let controller = harness.controller
        let before = try Data(contentsOf: harness.configURL)
        let calls = harness.runner.calls
        #expect(controller.spareKeyOffer(for: .key("caps_lock")) == .key("f20"))
        _ = controller.hotkeyUnavailableText(for: .key("caps_lock"))
        _ = controller.rebindHotkeyNotes(for: .key("caps_lock"), becoming: .key("f20"))
        #expect(try Data(contentsOf: harness.configURL) == before)
        #expect(harness.runner.calls == calls)
        #expect(controller.binding(for: .key("caps_lock")) == nil)
    }

    @Test func keysThatCantCarryHotkeysSayWhy() async throws {
        let harness = try await make(profileP(
            [("caps_lock", "vk_none"), ("tab", "mission_control"), ("a", "left_control")],
            simple: [HotkeyFixtures.toList("q", #"[{ "key_code": "a" }, { "key_code": "b" }]"#)]))
        defer { harness.remove() }
        let controller = harness.controller
        #expect(controller.hotkeyUnavailableText(for: .key("caps_lock")) == "Caps Lock is turned off in Karabiner-Elements.")
        #expect(controller.hotkeyUnavailableText(for: .key("tab")) == "Tab sends Mission control, which can\u{2019}t be a hotkey.")
        #expect(controller.hotkeyUnavailableText(for: .key("q")) == "Q sends several keys at once, through a simple rebind.")
        // Left Control is Sprint by default.
        #expect(controller.hotkeyUnavailableText(for: .key("a"))
            == "macOS can\u{2019}t use Left Control alone as a hotkey. Minecraft uses it for Sprint by default.")
        #expect(controller.spareKeyOffer(for: .key("caps_lock")) == .key("f20"))
        #expect(controller.spareKeyOffer(for: .key("q")) == .key("f20"))
        #expect(controller.spareKeyOffer(for: .key("a")) == nil)
    }

    // MARK: Becomes

    @Test func becomesSaysWhenARebindGivesAKeyHotkeysOrStrandsThem() async throws {
        let harness = try await make(profileP([("caps_lock", "f18")]))
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        center.add(combo: HotkeyFixtures.combo("f18"), actions: [.toggle(.crosshair)])
        center.add(combo: HotkeyFixtures.combo("f20"), actions: [.toggle(.nbbOverlay)])
        #expect(await eventually { !controller.hotkeys(on: .key("caps_lock")).isEmpty })
        #expect(controller.rebindHotkeyNotes(for: .key("caps_lock"), becoming: .key("f20")) == [
            "Caps Lock will fire the sTools hotkey F20 (NBB Overlay).",
            "Its hotkey F18 (Crosshair) stays on F18, and no key will send F18.",
        ])
        #expect(controller.rebindHotkeyNotes(for: .key("a"), becoming: .key("f20")) == ["A will fire the sTools hotkey F20 (NBB Overlay)."])
        #expect(controller.rebindHotkeyNotes(for: .key("caps_lock"), becoming: .key("f18")).isEmpty)
        #expect(controller.rebindHotkeyNotes(for: .key("b"), becoming: .key("c")).isEmpty)
    }

    /// With nothing chosen, the panel shows what Remove Rebind would do, right under "Sends F18": worded as what
    /// would happen, never as what is.
    @Test func removeRebindSaysWhatItWouldDo() async throws {
        let harness = try await make(profileP([("caps_lock", "f18"), ("q", "w")]))
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        center.add(combo: HotkeyFixtures.combo("f18"), actions: [.toggle(.crosshair)])
        center.add(combo: HotkeyFixtures.combo("q"), actions: [.toggle(.nbbOverlay)])
        #expect(await eventually { !controller.hotkeys(on: .key("caps_lock")).isEmpty })
        #expect(controller.rebindHotkeyNotes(for: .key("caps_lock"), becoming: nil)
            == ["Remove Rebind would leave its hotkey F18 (Crosshair) on F18, and no key would send F18."])
        #expect(controller.rebindHotkeyNotes(for: .key("q"), becoming: nil)
            == ["Remove Rebind would make Q fire the sTools hotkey Q (NBB Overlay)."])
        #expect(controller.rebindHotkeyNotes(for: .key("a"), becoming: nil).isEmpty)
    }

    @Test func aHotkeyAnotherKeyStillSendsIsNotStranded() async throws {
        let harness = try await make(profileP([("caps_lock", "f18"), ("right_option", "f18")]))
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        center.add(combo: HotkeyFixtures.combo("f18"), actions: [.toggle(.crosshair)])
        center.add(combo: HotkeyFixtures.combo("f18", .shift), actions: [.toggle(.nbbOverlay)])
        #expect(await eventually { controller.hotkeys(on: .key("caps_lock")).count == 2 })
        #expect(controller.rebindHotkeyNotes(for: .key("caps_lock"), becoming: nil).isEmpty)
        // Without the other key, both are stranded.
        let alone = try await make(profileP([("caps_lock", "f18")]))
        defer { alone.remove() }
        alone.center?.add(combo: HotkeyFixtures.combo("f18"), actions: [.toggle(.crosshair)])
        alone.center?.add(combo: HotkeyFixtures.combo("f18", .shift), actions: [.toggle(.nbbOverlay)])
        #expect(alone.controller.rebindHotkeyNotes(for: .key("caps_lock"), becoming: nil)
            == ["Remove Rebind would leave its hotkeys F18 (Crosshair) and \u{21E7}F18 (NBB Overlay) on F18, and no key would send F18."])
        #expect(alone.controller.rebindHotkeyNotes(for: .key("caps_lock"), becoming: .key("f19"))
            == ["Its hotkeys F18 (Crosshair) and \u{21E7}F18 (NBB Overlay) stay on F18, and no key will send F18."])
    }

    // MARK: Where hotkeys listen

    @Test func theKeyPanelSaysWhereItsHotkeysListen() async throws {
        let harness = try await make(profileP([("caps_lock", "f18"), ("right_option", "f18")]))
        defer { harness.remove() }
        let controller = harness.controller
        #expect(controller.hotkeySourceNote(for: .key("caps_lock"))
            == "Karabiner turns Caps Lock into F18, so its hotkeys listen for F18. Right Option fires them too.")
        #expect(controller.hotkeySourceNote(for: .key("a")) == nil)
        #expect(controller.hotkeySourceNote(for: .key("left_shift")) == nil)
        controller.chooseLayout(shape: .ansi, formFactor: .fullSize)
        #expect(controller.hotkeySourceNote(for: .key("caps_lock"))
            == "Karabiner turns Caps Lock into F18, so its hotkeys listen for F18. F18 and Right Option fire them too.")
        #expect(controller.hotkeySourceNote(for: .key("f18")) == "Caps Lock and Right Option fire them too.")
        controller.setScope(TestConfig.keyboard)
        #expect(controller.hotkeySourceNote(for: .key("caps_lock"))?.hasPrefix("Karabiner turns Caps Lock into F18 on this device, so") == true)

        let one = try await make(profileP([("caps_lock", "f18")]), ready: false, formFactor: .fullSize)
        defer { one.remove() }
        #expect(one.controller.hotkeySourceNote(for: .key("caps_lock"))
            == "Karabiner turns Caps Lock into F18, so its hotkeys listen for F18 while Karabiner-Elements runs. The F18 key fires them too.")
    }

    // MARK: Advice for Home

    @Test func notesGiveTheGameCautionAndTheHeldModifierNote() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        let caution = HotkeyNote(tone: .caution, text: "Minecraft uses F3 for Debug screen. While hotkeys are on, it never gets F3.")
        let held = HotkeyNote(
            tone: .note, text: "F3 doesn\u{2019}t fire while you hold Shift (Sneak) or Control (Sprint), as Minecraft binds them by default.")
        #expect(controller.notes(for: HotkeyFixtures.combo("f3")) == [caution, held])
        #expect(center.notes(for: HotkeyFixtures.combo("f3")).prefix(2) == [caution, held])
        #expect(controller.notes(for: HotkeyFixtures.combo("f18", [.control, .shift])).isEmpty)
        #expect(controller.notes(for: HotkeyCombo(keyCode: 56, modifiers: [])).isEmpty)
    }

    @Test func placementSaysWhichKeysSendAHotkeysKey() async throws {
        let harness = try await make(profileP([("caps_lock", "f20")], simple: [HotkeyFixtures.buttonPair("button4", "f20")]))
        defer { harness.remove() }
        let controller = harness.controller
        #expect(controller.placement(of: HotkeyFixtures.combo("f20", .option)) == HotkeyPlacement(text: "On Caps Lock and Mouse Button 4", canShow: true))
        #expect(controller.placement(of: HotkeyFixtures.combo("a")) == HotkeyPlacement(text: nil, canShow: true))
        #expect(controller.placement(of: HotkeyFixtures.combo("f19")) == HotkeyPlacement(text: "No key on your keyboard sends F19", canShow: false))

        let single = try await make(profileP([("caps_lock", "f20")], rules: [HotkeyFixtures.tapHoldRule("tab", held: "left_control", alone: "escape")]))
        defer { single.remove() }
        #expect(single.controller.placement(of: HotkeyFixtures.combo("f20")) == HotkeyPlacement(text: "On Caps Lock", canShow: true))
        #expect(single.controller.placement(of: HotkeyFixtures.combo("f19"))
            == HotkeyPlacement(text: "No key on your keyboard sends F19, unless a rule does", canShow: false))

        let noKeyboard = try Harness(hotkeys: true)
        defer { noKeyboard.remove() }
        #expect(noKeyboard.controller.placement(of: HotkeyFixtures.combo("a")) == nil)
        #expect(!noKeyboard.controller.selectKey(for: HotkeyFixtures.combo("a")))
    }

    @Test func selectKeyPicksTheFirstKeyThatSendsIt() async throws {
        let harness = try await make(profileP([("caps_lock", "f20")], simple: [HotkeyFixtures.buttonPair("button4", "f20")]))
        defer { harness.remove() }
        let controller = harness.controller
        #expect(controller.selectKey(for: HotkeyFixtures.combo("f20", .shift)))
        #expect(controller.selectedKey == .key("caps_lock"))
        #expect(!controller.selectKey(for: HotkeyFixtures.combo("f19")))
        #expect(controller.selectedKey == .key("caps_lock"))
    }

    @Test func prepareAdviceReadsTheFilesWithoutKarabinersCommandLineTool() async throws {
        let harness = try Harness(config: capsToF13, hotkeys: true)
        defer { harness.remove() }
        let controller = harness.controller
        let options = harness.directory.appending(path: "options.txt")
        controller.settings.customOptionsFilePath = options.path
        #expect(controller.minecraftKeybinds == nil)
        #expect(controller.config == nil)
        try Data("key_key.hotbar.1:key.keyboard.f13\n".utf8).write(to: options)

        await controller.prepareAdvice()
        #expect(controller.config != nil)
        #expect(controller.currentProfile == "P")
        #expect(controller.minecraftKeybinds != nil)
        #expect(harness.runner.calls.isEmpty)
        controller.chooseLayout(shape: .ansi, formFactor: .laptop)
        #expect(controller.placement(of: HotkeyFixtures.combo("f13")) == HotkeyPlacement(text: "On Caps Lock", canShow: true))
        #expect(controller.placement(of: HotkeyFixtures.combo("f20")) == HotkeyPlacement(text: "No key on your keyboard sends F20", canShow: false))
        #expect(controller.notes(for: HotkeyFixtures.combo("f13")).first?.text
            == "Minecraft uses F13 for Hotbar 1. While hotkeys are on, it never gets F13.")
    }

    // MARK: Tester

    @Test func theTesterNamesTheArrivedKeysHotkeysAndThePause() async throws {
        let harness = try await make()
        defer { harness.remove() }
        let center = try #require(harness.center)
        let controller = harness.controller
        let id = center.add(combo: HotkeyFixtures.combo("f13"), actions: [.toggle(.crosshair)])
        center.isEnabled = true
        #expect(!center.isPaused)
        // Test keys pauses hotkeys while it listens, so their keys arrive here.
        controller.isTesting = true
        #expect(center.isPaused)
        #expect(center.pauses == [.keyRebinder])
        controller.testerPressed(.key("f13"))
        #expect(controller.lastTrace?.hotkeys.map(\.id) == [id])
        #expect(controller.lastTrace?.hotkeysArePaused == true)
        #expect(controller.lastTrace?.summary().hasSuffix("sTools hotkey on F13: F13 (Crosshair). It pauses while Test keys is on.") == true)

        controller.isTesting = false
        #expect(!center.isPaused)
        controller.isCapturingOutput = true
        #expect(center.pauses == [.keyRebinder])
        controller.isCapturingOutput = false
        #expect(center.pauses.isEmpty)
        controller.isTesting = true
        controller.settings.showsHotkeys = false
        controller.testerPressed(.key("f13"))
        #expect(controller.lastTrace?.hotkeys.isEmpty == true)
    }
}
