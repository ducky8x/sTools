import AppKit
import Foundation
import STDesign
@testable import STPlatform
import SwiftUI
import Testing
@testable import KeyRebinder

// MARK: - A Key Rebinder with hotkeys

/// Answers each `karabiner_cli` command by its first argument, like Karabiner-Elements 16.3.0 with one profile "P".
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

/// A Key Rebinder controller over temporary folders, connected to a hotkey list that registers through a fake. The
/// command-line tool is scripted and nothing touches `~/.config/karabiner`; no hotkey is ever really registered.
@MainActor
final class HotkeyViewRig {
    let directory: URL
    let configURL: URL
    let controller: KeyRebinderController
    let center: HotkeyCenter
    let registrar = FakeHotkeyRegistrar()

    /// - Parameters:
    ///   - config: the starting `karabiner.json`, profile "P"; nil writes none.
    ///   - ready: whether Karabiner-Elements answers, which editing rebinds (and Use F20) needs.
    init(config: String?, ready: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "stools-hotkey-views-\(UUID().uuidString)", directoryHint: .isDirectory)
        let karabiner = directory.appending(path: "karabiner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: karabiner, withIntermediateDirectories: true)
        configURL = karabiner.appending(path: "karabiner.json")
        if let config { try Data(config.utf8).write(to: configURL) }
        let cli = KarabinerCLI(runner: ScriptedCLI(), cliURL: directory.appending(path: "karabiner_cli"), fileExists: { _ in true })
        let probes = KarabinerProbes(appBundleExists: { true }, cliVersion: { ready ? "16.3.0" : nil }, configReadable: { true })
        let settings = SettingsStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory))
        let services = ToolServices(
            settings: settings, displays: DisplayDirectory(),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource()),
            permissions: PermissionCenter(prober: GrantsEverything(), openURL: { _ in }))
        controller = KeyRebinderController(
            services: services, configURL: configURL,
            backupsDirectory: directory.appending(path: "backups", directoryHint: .isDirectory), cli: cli, probes: probes)
        center = HotkeyCenter(store: settings, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        controller.connect(hotkeys: center)
    }

    /// Loads Karabiner's state and the file, draws `shape` `formFactor` and turns hotkeys on (or leaves them off).
    func prepare(_ shape: KeyboardShape = .ansi, _ formFactor: KeyboardFormFactor = .laptop, hotkeysOn: Bool = true) async {
        await controller.refresh()
        controller.chooseLayout(shape: shape, formFactor: formFactor)
        center.isEnabled = hotkeysOn
    }

    /// Adds a hotkey and waits the main-actor turn the controller takes to place it.
    @discardableResult
    func add(_ code: String, _ modifiers: HotkeyCombo.Modifiers = [], _ actions: [HotkeyAction] = [.toggle(.crosshair)]) async -> UUID {
        let id = center.add(combo: HotkeyFixtures.combo(code, modifiers), actions: actions)
        _ = await eventually { self.controller.derived.hotkeysByKey.values.contains { $0.contains { $0.id == id } }
            || self.controller.derived.unplacedHotkeys.contains { $0.id == id } }
        return id
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// `karabiner.json` with profile "P" holding these key-to-key rebinds, raw Simple Modifications and rules.
    static func profile(_ pairs: [(String, String)] = [], simple: [String] = [], rules: [String] = []) -> String {
        HotkeyFixtures.config(pairs, simple: simple, rules: rules).serialized()
    }
}


// MARK: - Rendering

/// Renders `view` offscreen at 1x in the dark appearance as PNG data: an `NSHostingView` drawn into a bitmap of a
/// fixed scale, with no window, so nothing ever reaches a screen and the result doesn't depend on the display.
@MainActor
private func png<V: View>(_ view: V, size: CGSize) -> Data {
    let root = view
        .environment(\.stTheme, STTheme())
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(STColor.background)
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

// MARK: - Key caps

@MainActor
@Suite("Key cap hotkey marks")
struct KeyCapHotkeyMarkTests {
    private let unit: CGFloat = 48

    private func cap(_ state: KeyCapState, height: CGFloat = 1) -> Data {
        let parts = [CGRect(x: 0, y: 0, width: unit, height: unit * height)]
        return png(KeyCapView(legend: "f18", parts: parts, state: state, unit: unit).padding(12),
                   size: CGSize(width: unit + 24, height: unit * height + 24))
    }

    @Test func aWorkingAndABrokenHotkeyEachDrawTheirOwnRing() {
        var state = KeyCapState(action: "SNEAK")
        let plain = cap(state)
        state.hotkey = .working
        let working = cap(state)
        state.hotkey = .broken
        let broken = cap(state)
        #expect(plain != working)
        #expect(plain != broken)
        #expect(working != broken)
    }

    @Test func theRingJoinsTheRuleMarkAndTheRedDotInOneBadge() {
        var state = KeyCapState(isRuleDriven: true, isFlagged: true)
        let without = cap(state)
        state.hotkey = .working
        #expect(cap(state) != without)
    }

    @Test func aHalfHeightArrowCarriesTheRing() {
        var state = KeyCapState()
        let plain = cap(state, height: 0.5)
        state.hotkey = .working
        #expect(cap(state, height: 0.5) != plain)
    }
}

// MARK: - The plate

@MainActor
@Suite("Key Rebinder plate hotkeys", .serialized)
struct KeyboardPlateHotkeyTests {
    private let laptop = KeyboardLayout(shape: .ansi, formFactor: .laptop)

    @Test func aKeyThatFiresAHotkeyWearsItsRingOnlyWhileThePlateShowsHotkeys() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f13")]))
        defer { rig.remove() }
        await rig.prepare()
        await rig.add("f13", .option)
        let controller = rig.controller
        #expect(KeyboardPlate.capState(for: .key("caps_lock"), controller: controller, layout: laptop, showsHotkeys: true).hotkey == .working)
        #expect(KeyboardPlate.capState(for: .key("caps_lock"), controller: controller, layout: laptop, showsHotkeys: false).hotkey == nil)
        #expect(KeyboardPlate.capState(for: .key("a"), controller: controller, layout: laptop, showsHotkeys: true).hotkey == nil)

        rig.registrar.refused = [HotkeyFixtures.combo("f13")]
        await rig.add("f13")
        #expect(KeyboardPlate.capState(for: .key("caps_lock"), controller: controller, layout: laptop, showsHotkeys: true).hotkey == .broken)
    }

    @Test func aHotkeyFindingsRedDotShowsOnlyWhileThePlateShowsHotkeys() async throws {
        let rig = try HotkeyViewRig(config: nil)
        defer { rig.remove() }
        await rig.prepare()
        await rig.add("f3")
        let controller = rig.controller
        #expect(!controller.derived.hotkeyFindings.isEmpty)
        #expect(KeyboardPlate.capState(for: .key("f3"), controller: controller, layout: laptop, showsHotkeys: true).isFlagged)
        #expect(!KeyboardPlate.capState(for: .key("f3"), controller: controller, layout: laptop, showsHotkeys: false).isFlagged)
    }

    @Test func theDescriptionNamesTheKeysHotkeysOnlyWhileThePlateShowsThem() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f13")]))
        defer { rig.remove() }
        await rig.prepare()
        await rig.add("f13", .option)
        await rig.add("f3")
        let controller = rig.controller
        #expect(KeyboardPlate.description(of: .key("caps_lock"), controller: controller, showsHotkeys: true)
            == "Caps Lock. Sends F13. sTools hotkey Option F13: Crosshair.")
        #expect(KeyboardPlate.description(of: .key("caps_lock"), controller: controller, showsHotkeys: false)
            == "Caps Lock. Sends F13.")
        #expect(KeyboardPlate.description(of: .key("f3"), controller: controller, showsHotkeys: true)
            == "F3. Not rebound. sTools hotkey F3: Crosshair. The checker found a problem.")
        #expect(KeyboardPlate.description(of: .key("f3"), controller: controller, showsHotkeys: false) == "F3. Not rebound.")
    }

    @Test func theLegendExplainsTheRingOnlyWhileAKeyWearsOne() {
        let base = "Gold is what a key sends now. \u{25C6} a rule drives the key; select it to see the rule."
        let ring = " A gold ring is an sTools hotkey; a slashed red ring is one that isn\u{2019}t working."
        let dot = " A red dot is a checker finding."
        #expect(KeyboardPlate.legend(checkerEnabled: false, drawsHotkeyMarks: false) == base)
        #expect(KeyboardPlate.legend(checkerEnabled: true, drawsHotkeyMarks: false) == base + dot)
        #expect(KeyboardPlate.legend(checkerEnabled: true, drawsHotkeyMarks: true) == base + ring + dot)
        #expect(KeyboardPlate.legend(checkerEnabled: false, drawsHotkeyMarks: true) == base + ring)
    }

    /// Rings on the four half-height arrows, a rule-driven key (◆) and a checker finding, on a laptop ANSI plate.
    @Test func aLaptopPlateWithRingsOnTheArrowsARuleAndAFindingRenders() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile(rules: [HotkeyFixtures.tapHoldRule("caps_lock", held: "left_control", alone: "escape")]))
        defer { rig.remove() }
        await rig.prepare()
        for arrow in ["left_arrow", "up_arrow", "down_arrow", "right_arrow"] { await rig.add(arrow) }
        await rig.add("f3")
        let controller = rig.controller
        #expect(controller.hotkeyMark(for: .key("up_arrow")) == .working)
        #expect(KeyboardPlate.capState(for: .key("caps_lock"), controller: controller, layout: laptop, showsHotkeys: true).isRuleDriven)
        let size = CGSize(width: 1100, height: 560)
        let shown = png(KeyboardPlate(controller: controller, layout: laptop), size: size)
        let hidden = png(KeyboardPlate(controller: controller, layout: laptop, showsHotkeys: false), size: size)
        #expect(!shown.isEmpty)
        #expect(shown != hidden)
    }
}
