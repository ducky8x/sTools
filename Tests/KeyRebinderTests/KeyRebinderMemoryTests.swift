import AppKit
import Foundation
import Observation
import STDesign
@testable import STPlatform
import SwiftUI
import Testing
@testable import KeyRebinder

// What the Key Rebinder keeps after its page closes. Karabiner's file is read into a tree that costs about four times
// its size in memory. The store kept the last file it read, tree and bytes, for as long as the app ran, and the
// controller (which lives as long as the app too) kept the tree.

private final class ScriptedCLI: CommandRunner, @unchecked Sendable {
    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        switch args.first {
        case "--version": CommandResult(stdout: "16.3.0\n")
        case "--list-profile-names", "--show-current-profile-name": CommandResult(stdout: "P\n")
        case "--list-connected-devices": CommandResult(stdout: "[]")
        default: CommandResult(stdout: "", stderr: "unknown command", status: 1)
        }
    }
}

private struct GrantsEverything: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// A `karabiner.json` with profile "P", one rebind (Caps Lock to F3) and `rules` complex rules of a few manipulators each.
/// Every rule starts from its own key and modifiers, so the checker finds nothing to say about them.
private func configText(rules: Int) -> String {
    let keys = (Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init) + (1...20).map { "f\($0)" }
        + ["up_arrow", "down_arrow", "left_arrow", "right_arrow", "tab", "spacebar", "comma", "period", "slash", "semicolon", "quote",
           "open_bracket", "close_bracket", "backslash", "hyphen", "equal_sign", "home", "end", "page_up", "page_down"])
    let modifiers = ["left_command", "left_shift", "left_control", "left_option", "right_command", "right_shift", "right_control", "right_option"]
    let complexRules = (0..<rules).map { index in
        let key = keys[index % keys.count]
        let held = (0..<8).filter { (index / keys.count + 1) >> $0 & 1 == 1 }.map { "\"\(modifiers[$0])\"" }.joined(separator: ", ")
        return """
        {"description": "Rule number \(index) that does something with a long enough description to take space", "manipulators": [
          {"type": "basic", "from": {"key_code": "\(key)", "modifiers": {"mandatory": [\(held)], "optional": ["caps_lock"]}},
           "to": [{"key_code": "keypad_1"}],
           "conditions": [{"type": "frontmost_application_if", "bundle_identifiers": ["^com\\\\.example\\\\.app\(index)$"]}]}
        ]}
        """
    }.joined(separator: ",")
    return """
    {"global": {"show_in_menu_bar": true},
     "profiles": [{"name": "P", "selected": true,
       "simple_modifications": [{"from": {"key_code": "caps_lock"}, "to": [{"key_code": "f3"}]}],
       "complex_modifications": {"parameters": {}, "rules": [\(complexRules)]}}]}
    """
}

/// A Key Rebinder controller over temporary folders, with the command-line tool scripted. Nothing touches
/// `~/.config/karabiner`.
@MainActor
private final class Rig {
    let directory: URL
    let configURL: URL
    let controller: KeyRebinderController

    init(rules: Int = 3) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "stools-memory-\(UUID().uuidString)", directoryHint: .isDirectory)
        let karabiner = directory.appending(path: "karabiner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: karabiner, withIntermediateDirectories: true)
        configURL = karabiner.appending(path: "karabiner.json")
        try Data(configText(rules: rules).utf8).write(to: configURL)
        let cli = KarabinerCLI(runner: ScriptedCLI(), cliURL: directory.appending(path: "karabiner_cli"), fileExists: { _ in true })
        let probes = KarabinerProbes(appBundleExists: { true }, cliVersion: { "16.3.0" }, configReadable: { true })
        let settings = SettingsStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory))
        let services = ToolServices(
            settings: settings, displays: DisplayDirectory(),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource()),
            permissions: PermissionCenter(prober: GrantsEverything(), openURL: { _ in }))
        controller = KeyRebinderController(
            services: services, configURL: configURL,
            backupsDirectory: directory.appending(path: "backups", directoryHint: .isDirectory), cli: cli, probes: probes)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// What a value holds on to: the bytes of JSON in the parsed trees (`JSONValue`, `KarabinerConfig`, `KarabinerProfile`) and
/// of `Data` and `String` reachable from it. It follows stored properties, enum payloads and collection elements, once for
/// each object. A test of what an object retains reads the object, not the process's heap, which every suite running
/// beside it changes. A key's own event is a few dozen bytes of JSON too, so a test allows for those and not for a file.
private struct Holdings {
    var json = 0
    var bytes = 0
    var visited = 0
}

private func holdings(of value: Any, depth: Int = 10) -> Holdings {
    var found = Holdings()
    var seen = Set<ObjectIdentifier>()
    func visit(_ value: Any, _ depth: Int) {
        found.visited += 1
        switch value {
        case let tree as JSONValue:
            found.json += tree.serialized().utf8.count
            return
        case let config as KarabinerConfig:
            found.json += config.root.serialized().utf8.count
            return
        case let profile as KarabinerProfile:
            found.json += profile.json.serialized().utf8.count
            return
        case let data as Data:
            found.bytes += data.count
            return
        case let text as String:
            found.bytes += text.utf8.count
            return
        case is URL:
            return
        default:
            break
        }
        guard depth > 0, found.visited < 500_000 else { return }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class {
            guard seen.insert(ObjectIdentifier(value as AnyObject)).inserted else { return }
        }
        for child in mirror.children { visit(child.value, depth - 1) }
    }
    visit(value, depth)
    return found
}

@MainActor
private func spin(_ seconds: TimeInterval) {
    let end = SuspendingClock.now.advanced(by: .seconds(seconds))
    repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } while SuspendingClock.now < end
}

@MainActor
@Suite("Key Rebinder memory", .serialized)
struct KeyRebinderMemoryTests {
    // MARK: What the controller keeps

    @Test func closingThePageLetsGoOfTheLoadedFileAndKeepsWhatTheFirstFrameNeeds() async throws {
        let rig = try Rig()
        let controller = rig.controller
        await controller.refresh()
        #expect(controller.config != nil && controller.hasLoadedConfig)
        let rebinds = controller.derived.rebinds
        let bindings = controller.derived.bindings
        #expect(rebinds.map(\.from) == [.key("caps_lock")])

        controller.releaseLoadedFile()
        #expect(controller.config == nil, "the parsed file is still held")
        #expect(controller.hasLoadedConfig, "the page would draw as if there were no file")
        #expect(controller.derived.rebinds == rebinds)
        #expect(controller.derived.bindings == bindings)
        #expect(controller.canEdit)
        #expect(controller.profileNames == ["P"] && controller.currentProfile == "P")

        await controller.refresh()
        #expect(controller.config != nil)
        #expect(controller.derived.rebinds == rebinds)
    }

    @Test func aChangeWhileTheFileIsLetGoKeepsWhatTheKeysShow() async throws {
        let rig = try Rig()
        let controller = rig.controller
        await controller.refresh()
        let rebinds = controller.derived.rebinds
        controller.releaseLoadedFile()
        // A setting that makes the controller work out what the keys show again.
        controller.settings.checkerEnabled.toggle()
        #expect(controller.derived.rebinds == rebinds, "working it out again without the file emptied the keys")
        #expect(controller.derived.bindings[.key("caps_lock")] != nil)
    }

    @Test func anEditWaitingForConfirmationKeepsTheFileLoaded() async throws {
        let rig = try Rig()
        let controller = rig.controller
        await controller.refresh()
        // Someone else edits the file after sTools read it, so the next edit waits for a confirmation.
        let outside = try RebindEditor.setRebind(in: try JSONValue.parse(data: Data(contentsOf: rig.configURL)), profile: "P",
                                                 from: .key("q"), to: .key("w"))
        try Data(outside.serialized().utf8).write(to: rig.configURL)
        await controller.setRebind(.key("a"), to: .key("b"))
        #expect(controller.pendingEdit != nil)

        controller.releaseLoadedFile()
        #expect(controller.pendingEdit != nil, "the preview was dropped")
        #expect(controller.config != nil, "the file was let go under a preview that needs it")
    }

    /// The page can close while the file is still being read; the tree that arrives afterwards isn't kept.
    @Test func aFileThatFinishesLoadingAfterThePageClosedIsNotKept() async throws {
        let rig = try Rig()
        let controller = rig.controller
        let reading = Task { await controller.reloadConfig() }
        await Task.yield()
        controller.releaseLoadedFile()
        await reading.value
        #expect(controller.config == nil, "a file read after the page closed was kept")
    }

    // MARK: What is held

    /// The walk has to see what it looks for, or a pass means nothing.
    @Test func theWalkSeesParsedFilesAndBytes() throws {
        let tree = try JSONValue.parse(#"{"profiles": []}"#)
        let size = tree.serialized().utf8.count
        #expect(size > 0 && holdings(of: tree).json == size)
        #expect(holdings(of: KarabinerConfig(root: tree)).json == size)
        #expect(holdings(of: [Data(count: 5_000), Data(count: 20)]).bytes == 5_020)
        let nested = (name: "a profile", cache: [Optional(tree)])
        #expect(holdings(of: nested).json == size, "a file inside an optional inside an array wasn't found")
        #expect(holdings(of: nested).bytes == 9)
    }

    /// While the page is open the controller holds the parsed file; once it closes, nothing the controller reaches (the
    /// store, the rebinds and rules it kept, a pending edit) holds more JSON than a few keys' own events. A 300-rule
    /// file, so the tree is big.
    @Test func theParsedFileIsHeldOnlyWhileThePageIsOpen() async throws {
        let rig = try Rig(rules: 300)
        await rig.controller.refresh()
        let open = holdings(of: rig.controller)
        #expect(open.json > 100_000, "the control: the walk should find the file the page just loaded, it found \(open.json) bytes of JSON")

        rig.controller.releaseLoadedFile()
        let closed = holdings(of: rig.controller)
        #expect(closed.json < 2_000, "\(closed.json) bytes of parsed JSON are still reachable from the controller after the page closed")
        #expect(closed.visited < 500_000, "the walk gave up, so it proves nothing")
    }

    /// The store used to keep the file it last read, tree and bytes, to compare digests with, and only ever read the
    /// digest. Everything it holds between calls is the digests, a few dozen bytes.
    @Test func theStoreKeepsOnlyTheDigestOfTheFileItRead() async throws {
        let rig = try Rig(rules: 300)
        let store = KarabinerConfigStore(configURL: rig.configURL, backupsDirectory: rig.directory.appending(path: "store-backups"))
        let file = try await store.load()
        #expect(holdings(of: file).json > 100_000, "the control: the file the store returned is a parsed file")
        let kept = holdings(of: store)
        #expect(kept.json == 0, "the store still holds \(kept.json) bytes of parsed JSON")
        #expect(kept.bytes < 256, "the store holds \(kept.bytes) bytes of data and text, where a digest is 32")
    }

    /// An edit writes through the store, which keeps the digest of what it wrote and nothing else.
    @Test func theStoreKeepsOnlyADigestAfterAnEditToo() async throws {
        let rig = try Rig(rules: 300)
        await rig.controller.refresh()
        await rig.controller.setRebind(.key("a"), to: .key("b"))
        #expect(rig.controller.errorMessage == nil)
        #expect(rig.controller.derived.rebinds.map(\.from).contains(.key("a")))
        rig.controller.releaseLoadedFile()
        let closed = holdings(of: rig.controller)
        #expect(closed.json < 2_000, "\(closed.json) bytes of parsed JSON are still reachable from the controller after an edit and the close")
    }

    // MARK: The page

    /// A page that closes frees its views, lets go of the file and, back again, shows the keys at once from what it kept
    /// and then has the file again.
    @Test func thePageFreesItsViewsAndTheFileWhenItClosesAndComesBackWhole() async throws {
        let rig = try Rig()
        let controller = rig.controller
        let page = PageSwitch()
        STFont.register()
        weak var weakHost: NSView?
        let window: NSWindow
        do {
            let host = NSHostingView(rootView: SwitchingRoot(page: page, controller: controller))
            host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            weakHost = host
        }
        defer { window.contentView = nil }
        page.showsRebinder = true
        let shown = await eventually { controller.config != nil }
        #expect(shown, "the page never loaded the file")
        let rebinds = controller.derived.rebinds

        page.showsRebinder = false
        let letGo = await eventually { controller.config == nil }
        #expect(letGo, "the file is still held after the page closed")
        #expect(controller.hasLoadedConfig)

        page.showsRebinder = true
        spin(0.1)
        #expect(controller.hasLoadedConfig, "the page came back without its sections")
        #expect(controller.derived.rebinds == rebinds, "the page came back with empty keys")
        let loadedAgain = await eventually { controller.config != nil }
        #expect(loadedAgain, "the file was not read again")

        page.showsRebinder = false
        _ = await eventually { controller.config == nil }
        window.contentView = nil
        _ = await eventually { weakHost == nil }
        #expect(weakHost == nil, "the hosting view outlived its window")
    }
}

/// Waits (bounded, awake time) for `condition`, running the main run loop between looks.
@MainActor
private func eventually(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        spin(0.02)
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor @Observable
private final class PageSwitch {
    var showsRebinder = false
}

private struct SwitchingRoot: View {
    let page: PageSwitch
    let controller: KeyRebinderController

    var body: some View {
        ZStack {
            if page.showsRebinder {
                ScrollView { KeyRebinderView(controller: controller).padding(20) }
            } else {
                Text("Somewhere else")
            }
        }
        .environment(\.stTheme, STTheme())
        .environment(\.stSoundPlayer, .silent)
        .frame(width: 1200, height: 900)
        .background(STColor.background)
    }
}
