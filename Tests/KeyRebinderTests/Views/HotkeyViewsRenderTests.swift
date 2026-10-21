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
    ///   - connected: false leaves the controller without a hotkey list, like the Key Rebinder before the app wires it.
    init(config: String?, ready: Bool = true, connected: Bool = true) throws {
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
        if connected { controller.connect(hotkeys: center) }
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

/// `view` as the renders draw it: the house theme, no sounds, `size`, on the page's background.
@MainActor
private func rendered<V: View>(_ view: V, size: CGSize) -> some View {
    view
        .environment(\.stTheme, STTheme())
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(STColor.background)
}

/// An `NSHostingView` for `root`, in the dark appearance, with no window.
@MainActor
private func host<Root: View>(_ root: Root, size: CGSize) -> NSHostingView<Root> {
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    return host
}

/// Draws `host` offscreen at 1x as PNG data: into a bitmap of a fixed scale, with no window, so nothing ever reaches
/// a screen and the result doesn't depend on the display.
@MainActor
private func png(of host: NSView) -> Data {
    host.layoutSubtreeIfNeeded()
    let size = host.bounds.size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

/// Renders `view` offscreen at 1x in the dark appearance as PNG data (`png(of:)`).
@MainActor
private func png<V: View>(_ view: V, size: CGSize) -> Data {
    png(of: host(rendered(view, size: size), size: size))
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

// MARK: - The key panel's Hotkeys part

@MainActor
@Suite("Key panel hotkeys", .serialized)
struct KeyPanelHotkeyTests {
    @Test func theBlockSaysHotkeysAreOffUntilTheyAreTurnedOn() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f13")]))
        defer { rig.remove() }
        await rig.prepare(hotkeysOn: false)
        let controller = rig.controller
        #expect(KeyHotkeysBlock.content(for: .key("caps_lock"), controller: controller) == .off)
        #expect(KeyHotkeysBlock.content(for: .key("left_shift"), controller: controller) == .off)
        controller.turnHotkeysOn()
        #expect(KeyHotkeysBlock.content(for: .key("caps_lock"), controller: controller) == .carries(keyCode: 105))
        #expect(KeyHotkeysBlock.content(for: .key("a"), controller: controller) == .carries(keyCode: 0))
    }

    @Test func aKeyThatCantCarryHotkeysSaysWhyAndOffersTheSpareKey() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile(
            rules: [HotkeyFixtures.tapHoldRule("tab", held: "left_control", alone: "escape")]))
        defer { rig.remove() }
        await rig.prepare()
        let controller = rig.controller
        #expect(KeyHotkeysBlock.content(for: .key("caps_lock"), controller: controller) == .unavailable(
            reason: "macOS can\u{2019}t use Caps Lock alone as a hotkey.", spare: .key("f20"), isRuleDriven: false))
        #expect(KeyHotkeysBlock.content(for: .key("tab"), controller: controller) == .unavailable(
            reason: "A rule drives Tab, so sTools can\u{2019}t tell which key apps get. Add its hotkey in Home by pressing the key.",
            spare: nil, isRuleDriven: true))
        #expect(KeyHotkeysBlock.content(for: .pointing("button1"), controller: controller) == .unavailable(
            reason: "Left and right click can\u{2019}t be hotkeys.", spare: nil, isRuleDriven: false))
    }

    @Test func withoutKarabinerReadyKeysStillCarryHotkeysButUseF20IsHidden() async throws {
        let rig = try HotkeyViewRig(config: nil, ready: false)
        defer { rig.remove() }
        await rig.prepare()
        let controller = rig.controller
        #expect(!controller.canEdit)
        #expect(KeyHotkeysBlock.content(for: .key("f5"), controller: controller) == .carries(keyCode: 96))
        #expect(KeyHotkeysBlock.content(for: .key("caps_lock"), controller: controller) == .unavailable(
            reason: "macOS can\u{2019}t use Caps Lock alone as a hotkey.", spare: nil, isRuleDriven: false))
    }

    @Test func aNewDraftIsTheKeyAloneAndNeedsAnAction() async throws {
        let rig = try HotkeyViewRig(config: nil)
        defer { rig.remove() }
        await rig.prepare()
        var draft = HotkeyDraft()
        #expect(draft.editing == nil)
        #expect(draft.combo(on: 105) == HotkeyCombo(keyCode: 105, modifiers: []))
        #expect(draft.problem(on: 105, in: rig.center) == nil)
        #expect(!draft.canSave(on: 105, in: rig.center))
        draft.does = [.toggle(.crosshair)]
        #expect(draft.canSave(on: 105, in: rig.center))
        draft.hold = [.shift, .option]
        #expect(draft.combo(on: 105) == HotkeyCombo(keyCode: 105, modifiers: [.option, .shift]))
    }

    @Test func editingStartsFromTheHotkeysModifiersAndActions() {
        let binding = HotkeyBinding(combo: HotkeyCombo(keyCode: 79, modifiers: [.control, .command]), actions: [.startStopRecording, .toggle(.nbbOverlay)])
        let draft = HotkeyDraft(binding)
        #expect(draft.editing == binding.id)
        #expect(draft.hold == [.control, .command])
        #expect(draft.modifiers == [.control, .command])
        #expect(draft.does == [.startStopRecording, .toggle(.nbbOverlay)])
    }

    @Test func aDuplicateOrAReservedCombinationBlocksSaving() async throws {
        let rig = try HotkeyViewRig(config: nil)
        defer { rig.remove() }
        await rig.prepare()
        let f13 = await rig.add("f13")
        var draft = HotkeyDraft()
        draft.does = [.toggle(.nbbOverlay)]
        #expect(draft.problem(on: 105, in: rig.center) == "Already used by another hotkey")
        #expect(!draft.canSave(on: 105, in: rig.center))
        // Editing the hotkey that owns the combination isn't a duplicate of itself.
        draft.editing = f13
        #expect(draft.problem(on: 105, in: rig.center) == nil)
        #expect(draft.canSave(on: 105, in: rig.center))
        var quit = HotkeyDraft()
        quit.hold = [.command]
        quit.does = [.toggle(.crosshair)]
        #expect(quit.problem(on: 12, in: rig.center) == "Reserved: Quit")
        #expect(!quit.canSave(on: 12, in: rig.center))
    }

    @Test func theEditorOpensWhereItsDraftBelongsAndClosesOnceItsHotkeyLeftTheKey() {
        let binding = HotkeyBinding(combo: HotkeyCombo(keyCode: 79, modifiers: .option), actions: [.toggle(.crosshair)])
        let other = HotkeyBinding(combo: HotkeyCombo(keyCode: 79, modifiers: []), actions: [.toggle(.nbbOverlay)])
        #expect(KeyHotkeysBlock.editorPlace(for: nil, among: [binding]) == nil)
        #expect(KeyHotkeysBlock.editorPlace(for: HotkeyDraft(), among: [binding]) == .add)
        #expect(KeyHotkeysBlock.editorPlace(for: HotkeyDraft(), among: []) == .add)
        #expect(KeyHotkeysBlock.editorPlace(for: HotkeyDraft(binding), among: [other, binding]) == .row(binding.id))
        // The key sends something else now, so the hotkey isn't on it: Save Hotkey would move it to the new key.
        #expect(KeyHotkeysBlock.editorPlace(for: HotkeyDraft(binding), among: [other]) == nil)
        #expect(KeyHotkeysBlock.editorPlace(for: HotkeyDraft(binding), among: []) == nil)
    }

    @Test func theBlocksIdentityFollowsWhatTheKeySends() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare(hotkeysOn: false)
        let controller = rig.controller
        let before = KeyHotkeysBlock.identity(of: .key("caps_lock"), controller: controller)
        #expect(before == KeyHotkeysBlock.identity(of: .key("caps_lock"), controller: controller))
        #expect(before != KeyHotkeysBlock.identity(of: .key("a"), controller: controller))
        await controller.setRebind(.key("caps_lock"), to: .key("f20"))
        #expect(KeyHotkeysBlock.identity(of: .key("caps_lock"), controller: controller) != before)
        await controller.removeRebind(.key("caps_lock"))
        // Caps Lock sends itself, which can't carry hotkeys.
        #expect(KeyHotkeysBlock.identity(of: .key("caps_lock"), controller: controller) != before)
    }

    /// While a karabiner.json change waits for Save This or Discard, what the key sends may still change: rows' Edit,
    /// Add Hotkey…, the chips, Save Hotkey and Delete wait, and Cancel still closes the editor.
    @Test func whileAChangeWaitsOnlyCancelWorks() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        let id = await rig.add("f18", .option)
        let draft = HotkeyDraft(try #require(rig.center.bindings.first { $0.id == id }))
        let controller = rig.controller
        #expect(KeyHotkeysBlock.controls(for: draft, on: 79, controller: controller) == .init(edits: true, saves: true, cancels: true))
        #expect(KeyHotkeysBlock.controls(for: HotkeyDraft(), on: 79, controller: controller) == .init(edits: true, saves: false, cancels: true))
        let size = CGSize(width: 600, height: 520)
        func block(_ draft: HotkeyDraft?) -> Data {
            png(KeyHotkeysBlock(controller: controller, key: .key("caps_lock"), chosen: .constant(nil), openHotkeys: nil, draft: draft)
                .padding(16), size: size)
        }
        let rows = block(nil)
        let editor = block(draft)

        // karabiner.json changes elsewhere, then a rebind waits for Save This or Discard.
        let outside = try RebindEditor.setRebind(
            in: JSONValue.parse(data: Data(contentsOf: rig.configURL)), profile: "P", from: .key("q"), to: .key("w"))
        try Data(outside.serialized().utf8).write(to: rig.configURL)
        await controller.setRebind(.key("e"), to: .key("r"))
        #expect(controller.pendingEdit != nil)
        #expect(KeyHotkeysBlock.controls(for: draft, on: 79, controller: controller) == .init(edits: false, saves: false, cancels: true))
        #expect(KeyHotkeysBlock.controls(for: nil, on: 79, controller: controller) == .init(edits: false, saves: false, cancels: true))
        #expect(block(nil) != rows)
        #expect(block(draft) != editor)
    }

    @Test func holdOffersTheFourModifiersInMacOSOrder() {
        #expect(HotkeyDraft.holdChoices.map(\.title) == ["Control", "Option", "Shift", "Command"])
        #expect(HotkeyDraft.holdChoices.map(\.value) == [.control, .option, .shift, .command])
    }

    @Test func thePanelListsHotkeyFindingsAndBecomesCaptionsOnlyWhenItShowsHotkeys() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        await rig.add("f18")
        await rig.add("f20", [], [.toggle(.nbbOverlay)])
        await rig.add("f3")
        let controller = rig.controller
        #expect(KeyEditorPanel.findings(for: .key("f3"), controller: controller, showsHotkeys: true).map(\.kind) == [.hotkeyTakesGameKey])
        #expect(KeyEditorPanel.findings(for: .key("f3"), controller: controller, showsHotkeys: false).isEmpty)

        #expect(KeyEditorPanel.hotkeyCaptions(for: .key("caps_lock"), chosen: .key("f20"), controller: controller, showsHotkeys: true) == [
            "Caps Lock will fire the sTools hotkey F20 (NBB Overlay).",
            "Its hotkey F18 (Crosshair) stays on F18, and no key will send F18.",
        ])
        // Nothing chosen: what Remove Rebind would do, worded as a possibility under "Sends F18".
        #expect(KeyEditorPanel.hotkeyCaptions(for: .key("caps_lock"), chosen: nil, controller: controller, showsHotkeys: true)
            == ["Remove Rebind would leave its hotkey F18 (Crosshair) on F18, and no key would send F18."])
        // A key with no rebind to remove says nothing until an output is chosen.
        #expect(KeyEditorPanel.hotkeyCaptions(for: .key("a"), chosen: nil, controller: controller, showsHotkeys: true).isEmpty)
        #expect(KeyEditorPanel.hotkeyCaptions(for: .key("caps_lock"), chosen: .key("f20"), controller: controller, showsHotkeys: false).isEmpty)
    }
}

@MainActor
@Suite("Key panel hotkeys rendering", .serialized)
struct KeyPanelHotkeyRenderTests {
    @Test func theBlocksOffRowsWithEditorAndCantCarryStatesRenderDistinctly() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare(hotkeysOn: false)
        func block(_ key: KarabinerEvent, draft: HotkeyDraft? = nil) -> Data {
            png(KeyHotkeysBlock(controller: rig.controller, key: key, chosen: .constant(nil), openHotkeys: {}, draft: draft).padding(16),
                size: CGSize(width: 600, height: 420))
        }
        let off = block(.key("caps_lock"))

        rig.controller.turnHotkeysOn()
        let id = await rig.add("f18", .option, [.toggle(.crosshair), .toggle(.nbbOverlay)])
        await rig.add("f18")
        let edited = try #require(rig.center.bindings.first { $0.id == id })
        let rows = block(.key("caps_lock"))
        let rowsAndEditor = block(.key("caps_lock"), draft: HotkeyDraft(edited))
        let cantCarry = block(.key("left_shift"))

        #expect(Set([off, rows, rowsAndEditor, cantCarry]).count == 4)
    }

    /// The page keeps one key panel and changes its key; the panel gives the Hotkeys part a new identity per key, so
    /// an open editor closes and nothing is saved.
    @Test func selectingAnotherKeyClosesTheEditorUnsaved() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        let size = CGSize(width: 680, height: 640)
        func panel(_ key: KarabinerEvent, draft: HotkeyDraft? = nil) -> KeyEditorPanel {
            KeyEditorPanel(controller: rig.controller, key: key, hotkeyDraft: draft, openRule: { _ in })
        }
        var draft = HotkeyDraft()
        draft.does = [.toggle(.crosshair)]
        let page = host(rendered(panel(.key("caps_lock"), draft: draft), size: size), size: size)
        let editing = png(of: page)
        #expect(editing != png(panel(.key("caps_lock")), size: size))

        page.rootView = rendered(panel(.key("a")), size: size)
        let switched = png(of: page)
        #expect(switched == png(panel(.key("a")), size: size))
        #expect(switched != png(panel(.key("a"), draft: draft), size: size))
        #expect(rig.center.bindings.isEmpty)
    }

    /// "Hold" and "Does" stay on one line at every text size the app allows (Appearance ▸ Text size, 90–130%).
    @Test func theHoldAndDoesLabelsStayOnOneLineAtEveryTextSize() {
        _ = STFont.register()
        for scale in [0.9, 1.0, 1.3] {
            let theme = STTheme(textScale: scale)
            func height(_ view: some View) -> CGFloat {
                NSHostingView(rootView: view.environment(\.stTheme, theme)).fittingSize.height
            }
            let line = height(Text("D").stStyle(.label))
            for title in ["Hold", "Does"] {
                #expect(abs(height(KeyHotkeysBlock.ChipsLabel(title)) - line) < 0.5, "\(title) at \(scale)")
            }
        }
    }

    /// Editing ⌥F18 on Caps Lock (→ F18), then saving a rebind of Caps Lock in the same panel: the editor closes
    /// unsaved, instead of staying open as a new hotkey's editor that would move ⌥F18 to Caps Lock's new key.
    @Test func aRebindOfTheKeyClosesTheEditorOfOneOfItsHotkeys() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        let id = await rig.add("f18", .option)
        let edited = try #require(rig.center.bindings.first { $0.id == id })
        let size = CGSize(width: 680, height: 760)
        func panel(draft: HotkeyDraft? = nil) -> KeyEditorPanel {
            KeyEditorPanel(controller: rig.controller, key: .key("caps_lock"), hotkeyDraft: draft, openRule: { _ in })
        }
        let page = host(rendered(panel(draft: HotkeyDraft(edited)), size: size), size: size)
        #expect(png(of: page) != png(panel(), size: size))

        await rig.controller.setRebind(.key("caps_lock"), to: .key("f20"))
        #expect(rig.controller.hotkeyTarget(for: .key("caps_lock")).keyCode == 90)
        page.rootView = rendered(panel(), size: size)
        #expect(png(of: page) == png(panel(), size: size))
        #expect(rig.center.bindings.map(\.combo) == [HotkeyFixtures.combo("f18", .option)])
    }

    /// An editor adding a hotkey closes too when the key starts sending another key, rather than adding it there.
    @Test func aRebindOfTheKeyClosesTheEditorOfANewHotkey() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        var draft = HotkeyDraft()
        draft.hold = [.shift]
        draft.does = [.toggle(.nbbOverlay)]
        let size = CGSize(width: 680, height: 760)
        func panel(draft: HotkeyDraft? = nil) -> KeyEditorPanel {
            KeyEditorPanel(controller: rig.controller, key: .key("caps_lock"), hotkeyDraft: draft, openRule: { _ in })
        }
        let page = host(rendered(panel(draft: draft), size: size), size: size)
        #expect(png(of: page) != png(panel(), size: size))

        await rig.controller.setRebind(.key("caps_lock"), to: .key("f20"))
        page.rootView = rendered(panel(), size: size)
        #expect(png(of: page) == png(panel(), size: size))
        #expect(rig.center.bindings.isEmpty)
    }
}

// MARK: - Findings and settings

@MainActor
@Suite("Key Rebinder findings and settings with hotkeys", .serialized)
struct FindingsAndSettingsHotkeyTests {
    @Test func hotkeyFindingsShowEvenWithoutKarabinerJSONButNotInTheTrial() async throws {
        let rig = try HotkeyViewRig(config: nil)
        defer { rig.remove() }
        await rig.prepare()
        let controller = rig.controller
        #expect(controller.config == nil)
        #expect(!KeyRebinderView.showsFindings(controller: controller, showsHotkeys: true))
        await rig.add("f3")
        #expect(KeyRebinderView.showsFindings(controller: controller, showsHotkeys: true))
        #expect(!KeyRebinderView.showsFindings(controller: controller, showsHotkeys: false))
        #expect(FindingsSection.findings(controller: controller, showsHotkeyFindings: true).map(\.kind) == [.hotkeyTakesGameKey])
        #expect(FindingsSection.findings(controller: controller, showsHotkeyFindings: false).isEmpty)
        controller.settings.checkerEnabled = false
        #expect(!KeyRebinderView.showsFindings(controller: controller, showsHotkeys: true))
    }

    @Test func withKarabinerJSONTheSectionShowsWhileTheCheckerIsOn() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare(hotkeysOn: false)
        let controller = rig.controller
        #expect(KeyRebinderView.showsFindings(controller: controller, showsHotkeys: false))
        #expect(KeyRebinderView.showsFindings(controller: controller, showsHotkeys: true))
        controller.settings.checkerEnabled = false
        #expect(!KeyRebinderView.showsFindings(controller: controller, showsHotkeys: true))
    }

    @Test func theCaptionSaysHotkeyFindingsUseTheDefaultKeysWhenKeybindsAreUnknown() async throws {
        let unknown = "Advisory only: nothing is ever blocked. Without Minecraft\u{2019}s keybinds, speedrun-rule findings count every key as a game input"
        let known = "Advisory only: nothing is ever blocked. Speedrun-rule findings cover keys Minecraft uses."
        #expect(FindingsSection.caption(keybindsKnown: false, hotkeyFindingsCanShow: false) == unknown + ".")
        #expect(FindingsSection.caption(keybindsKnown: false, hotkeyFindingsCanShow: true)
            == unknown + ", and hotkey findings use Minecraft\u{2019}s default keys.")
        #expect(FindingsSection.caption(keybindsKnown: true, hotkeyFindingsCanShow: false) == known)
        #expect(FindingsSection.caption(keybindsKnown: true, hotkeyFindingsCanShow: true) == known)

        let rig = try HotkeyViewRig(config: nil)
        defer { rig.remove() }
        await rig.prepare(hotkeysOn: false)
        let controller = rig.controller
        #expect(!FindingsSection.hotkeyFindingsCanShow(controller: controller, showsHotkeyFindings: true))
        controller.turnHotkeysOn()
        #expect(FindingsSection.hotkeyFindingsCanShow(controller: controller, showsHotkeyFindings: true))
        #expect(!FindingsSection.hotkeyFindingsCanShow(controller: controller, showsHotkeyFindings: false))
        controller.settings.showsHotkeys = false
        #expect(!FindingsSection.hotkeyFindingsCanShow(controller: controller, showsHotkeyFindings: true))
    }

    @Test func showHotkeysIsOfferedOnlyWithAHotkeyListOutsideTheTrial() async throws {
        let rig = try HotkeyViewRig(config: nil)
        defer { rig.remove() }
        #expect(KeyRebinderSettingsSection.offersShowHotkeys(controller: rig.controller, showsHotkeys: true))
        #expect(!KeyRebinderSettingsSection.offersShowHotkeys(controller: rig.controller, showsHotkeys: false))
        let unconnected = try HotkeyViewRig(config: nil, connected: false)
        defer { unconnected.remove() }
        #expect(!KeyRebinderSettingsSection.offersShowHotkeys(controller: unconnected.controller, showsHotkeys: true))
    }

    @Test func resettingTheSettingsTurnsShowHotkeysBackOn() throws {
        let rig = try HotkeyViewRig(config: nil)
        defer { rig.remove() }
        rig.controller.settings.showsHotkeys = false
        rig.controller.resetToDefault()
        #expect(rig.controller.settings.showsHotkeys)
    }
}
