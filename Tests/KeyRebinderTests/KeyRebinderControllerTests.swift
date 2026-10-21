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

    init(config: String = twoProfiles, ready: Bool = true, symlink: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "stools-rebinder-\(UUID().uuidString)", directoryHint: .isDirectory)
        let karabiner = directory.appending(path: "karabiner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: karabiner, withIntermediateDirectories: true)
        configURL = karabiner.appending(path: "karabiner.json")
        if symlink {
            let real = directory.appending(path: "real.json")
            try Data(config.utf8).write(to: real)
            try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: real)
        } else {
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
        let services = ToolServices(
            settings: SettingsStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory)),
            displays: DisplayDirectory(),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource()),
            permissions: PermissionCenter(prober: AlwaysGranted()))
        controller = KeyRebinderController(
            services: services, configURL: configURL,
            backupsDirectory: directory.appending(path: "backups", directoryHint: .isDirectory), cli: cli, probes: probes)
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
