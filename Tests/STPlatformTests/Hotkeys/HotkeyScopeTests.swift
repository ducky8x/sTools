import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import STPlatform

/// Records what the center registers, and reports presses and releases like the Carbon registrar. Never touches the
/// system.
@MainActor
private final class ScopeRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    var onRelease: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]
    private(set) var log: [String] = []

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        active[id] = combo
        log.append("register \(combo.displayString)")
    }

    func unregister(id: UUID) {
        guard let combo = active.removeValue(forKey: id) else { return }
        log.append("unregister \(combo.displayString)")
    }
}

/// The app in front, switched by hand: never reads NSWorkspace.
@MainActor
private final class FakeFrontmostApp: FrontmostAppObserving {
    var frontmostProcessID: Int32?
    var onChange: (@MainActor () -> Void)?

    init(_ pid: Int32?) { frontmostProcessID = pid }

    func bringToFront(_ pid: Int32?) {
        frontmostProcessID = pid
        onChange?()
    }
}

private let sToolsPID: Int32 = 10
private let minecraftPID: Int32 = 200
private let secondMinecraftPID: Int32 = 201
private let browserPID: Int32 = 300

private let cmd1 = HotkeyCombo(keyCode: 18, modifiers: .command)
private let cmd3 = HotkeyCombo(keyCode: 20, modifiers: .command)
private let f13 = HotkeyCombo(keyCode: 105, modifiers: [])

private func minecraftInstance(pid: Int32) -> MinecraftInstance {
    MinecraftInstance(window: MinecraftWindow(windowNumber: UInt32(pid), processID: pid, title: "Minecraft* 1.16.1",
                                              frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                      launchDate: Date(timeIntervalSince1970: Double(pid)))
}

/// The processes the fake system has running; a game that quits is taken out by hand.
@MainActor
private final class FakeProcesses {
    var running: Set<Int32> = [sToolsPID, minecraftPID, secondMinecraftPID, browserPID]
}

/// A center on a fake registrar, told about the app in front by a real `HotkeyFrontAppWatcher` over a fake
/// frontmost app, a locator on a static source and fake running processes.
@MainActor
private final class ScopeHarness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hotkey-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store: SettingsStore
    let registrar = ScopeRegistrar()
    let frontmost: FakeFrontmostApp
    let source: StaticMinecraftWindowSource
    let locator: MinecraftLocator
    let center: HotkeyCenter
    let watcher: HotkeyFrontAppWatcher
    let processes = FakeProcesses()
    var events: [HotkeyEvent] = []

    init(front pid: Int32? = sToolsPID, minecraft: [Int32] = [minecraftPID], scope: HotkeyScope = .sToolsAndMinecraft) {
        store = SettingsStore(directory: directory, debounce: .milliseconds(1))
        store.save(HotkeySettings(isEnabled: true, scope: scope))
        frontmost = FakeFrontmostApp(pid)
        source = StaticMinecraftWindowSource(instances: minecraft.map(minecraftInstance(pid:)))
        locator = MinecraftLocator(source: source, coalescing: .zero)
        locator.start()
        var sink: (([HotkeyEvent]) -> Void)?
        center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { sink?($0) })
        watcher = HotkeyFrontAppWatcher(center: center, frontmost: frontmost, minecraft: locator, ownProcessID: sToolsPID,
                                        isRunning: { [processes] in processes.running.contains($0) })
        sink = { [unowned self] in events.append(contentsOf: $0) }
        watcher.start()
    }

    isolated deinit {
        locator.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = SuspendingClock.now + timeout
    while !condition() {
        if SuspendingClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("Where hotkeys work")
@MainActor
struct HotkeyScopeTests {
    // MARK: In sTools and Minecraft, the default

    @Test func underTheDefaultHotkeysAreRegisteredOnlyWithSToolsOrMinecraftInFront() {
        let h = ScopeHarness(front: sToolsPID)
        let a = h.center.add(combo: cmd1, actions: [.toggle(.crosshair)])
        let b = h.center.add(combo: f13, actions: [.startTimer])
        #expect(h.center.scope == .sToolsAndMinecraft)
        #expect(h.center.frontApp == .sTools)
        #expect(h.registrar.active == [a: cmd1, b: f13])

        h.frontmost.bringToFront(browserPID)
        #expect(h.center.frontApp == .other)
        #expect(!h.center.worksInFrontApp)
        #expect(h.registrar.active.isEmpty, "a browser's ⌘1 reaches the browser")
        #expect(h.center.status(of: a) == .registered, "an app switch never changes a status")
        #expect(h.center.activeBindings.map(\.id) == [a, b])

        h.frontmost.bringToFront(minecraftPID)
        #expect(h.center.frontApp == .minecraft)
        #expect(h.registrar.active == [a: cmd1, b: f13])
    }

    @Test func registrationFollowsEveryAppSwitch() {
        let h = ScopeHarness(front: browserPID, minecraft: [minecraftPID, secondMinecraftPID])
        h.center.add(combo: cmd3, actions: [.toggle(.crosshair)])
        #expect(h.registrar.log == ["register ⌘3", "unregister ⌘3"], "tried once with macOS while another app is in front")

        for (pid, registered) in [(minecraftPID, true), (browserPID, false), (sToolsPID, true), (nil, false),
                                  (secondMinecraftPID, true), (browserPID, false)] as [(Int32?, Bool)] {
            h.frontmost.bringToFront(pid)
            #expect(h.registrar.active.isEmpty != registered, "\(String(describing: pid))")
        }
    }

    /// Going between sTools and Minecraft, or between two other apps, keeps what is registered as it is.
    @Test func switchesThatDontChangeWhereHotkeysWorkCostNothing() {
        let h = ScopeHarness(front: sToolsPID)
        h.center.add(combo: cmd1, actions: [.toggle(.nbbOverlay)])
        let log = h.registrar.log
        h.frontmost.bringToFront(minecraftPID)
        h.frontmost.bringToFront(sToolsPID)
        h.frontmost.bringToFront(minecraftPID)
        #expect(h.registrar.log == log)

        h.frontmost.bringToFront(browserPID)
        let away = h.registrar.log
        h.frontmost.bringToFront(400)
        h.frontmost.bringToFront(browserPID)
        #expect(h.registrar.log == away)
    }

    @Test func aPressAfterLeavingIsIgnoredAndAHeldTimerKeyIsReleased() {
        let h = ScopeHarness(front: minecraftPID)
        let timer = h.center.add(combo: f13, actions: [.startTimer])
        h.registrar.onPress?(timer)
        #expect(h.events == [.startTimer])

        h.frontmost.bringToFront(browserPID)
        #expect(h.events == [.startTimer, .startTimerReleased], "macOS can't report that release any more")
        h.registrar.onPress?(timer)
        #expect(h.events == [.startTimer, .startTimerReleased], "a press macOS sent before the switch is stale")
    }

    /// The game's process came to the front before its window opened: it counts once the locator sees the window.
    @Test func aMinecraftWindowThatOpensWhileItsGameIsInFrontCounts() async {
        let h = ScopeHarness(front: minecraftPID, minecraft: [])
        h.center.add(combo: cmd1, actions: [.toggle(.nbbOverlay)])
        #expect(h.center.frontApp == .other)
        #expect(h.registrar.active.isEmpty)

        h.source.instances = [minecraftInstance(pid: minecraftPID)]
        #expect(await eventually { h.center.frontApp == .minecraft })
        #expect(h.registrar.active.count == 1)

        // Once seen, the game counts while its process runs, listed or not (`aGameStaysMinecraftWhile…`); when it
        // quits, it's forgotten.
        h.processes.running.remove(minecraftPID)
        h.source.instances = []
        #expect(await eventually { h.center.frontApp == .other })
        #expect(h.registrar.active.isEmpty)
    }

    /// The locator lists only the windows Accessibility can read now: a full-screen game on its own Space, or a game on
    /// another Space, drops out of its list while you're elsewhere. Switching back to it (⌘-Tab, a Spaces swipe) must
    /// find its hotkeys working at once, before the locator reads its window again.
    @Test func aGameStaysMinecraftWhileItsWindowIsOnAnotherSpace() async {
        let h = ScopeHarness(front: browserPID)
        let id = h.center.add(combo: cmd1, actions: [.toggle(.nbbOverlay)])
        h.source.instances = []
        #expect(await eventually { h.locator.instances.isEmpty })

        h.frontmost.bringToFront(minecraftPID)
        #expect(h.center.frontApp == .minecraft)
        #expect(h.registrar.active == [id: cmd1])

        h.frontmost.bringToFront(browserPID)
        #expect(h.registrar.active.isEmpty)
        h.frontmost.bringToFront(minecraftPID)
        #expect(h.registrar.active == [id: cmd1])
    }

    /// A game that quit is forgotten, so whatever process later has its number isn't taken for Minecraft. As in macOS,
    /// the quit brings another app to the front, which is when the watcher sees it.
    @Test func aGameThatQuitIsForgotten() async {
        let h = ScopeHarness(front: minecraftPID)
        h.center.add(combo: cmd1, actions: [.toggle(.nbbOverlay)])
        #expect(h.center.frontApp == .minecraft)
        h.processes.running.remove(minecraftPID)
        h.source.instances = []
        #expect(await eventually { h.locator.instances.isEmpty })
        h.frontmost.bringToFront(browserPID)

        h.processes.running.insert(minecraftPID)
        h.frontmost.bringToFront(minecraftPID)
        #expect(h.center.frontApp == .other)
        #expect(h.registrar.active.isEmpty)
    }

    /// A process the locator never listed isn't Minecraft, even a Java one (Ninjabrain Bot, a launcher).
    @Test func aProcessNeverListedIsntMinecraft() {
        let h = ScopeHarness(front: sToolsPID, minecraft: [])
        h.center.add(combo: cmd1, actions: [.toggle(.nbbOverlay)])
        h.frontmost.bringToFront(minecraftPID)
        #expect(h.center.frontApp == .other)
        #expect(h.registrar.active.isEmpty)
    }

    // MARK: Everywhere

    @Test func everywhereRegistersWhicheverAppIsInFront() {
        let h = ScopeHarness(front: browserPID, scope: .everywhere)
        let id = h.center.add(combo: cmd1, actions: [.toggle(.nbbOverlay)])
        #expect(h.center.worksInFrontApp)
        #expect(h.registrar.active == [id: cmd1])
        for pid in [sToolsPID, minecraftPID, browserPID, 400] {
            h.frontmost.bringToFront(pid)
            #expect(h.registrar.active == [id: cmd1])
        }
    }

    @Test func changingTheScopeAppliesAtOnceAndPersists() async {
        let h = ScopeHarness(front: browserPID)
        let id = h.center.add(combo: cmd1, actions: [.toggle(.nbbOverlay)])
        #expect(h.registrar.active.isEmpty)

        h.center.scope = .everywhere
        #expect(h.registrar.active == [id: cmd1])
        await h.store.flush()
        #expect(SettingsStore(directory: h.directory).load(HotkeySettings.self).scope == .everywhere)

        h.center.scope = .sToolsAndMinecraft
        #expect(h.registrar.active.isEmpty)
    }

    // MARK: Pieces

    /// Tests and previews never tell a center which app is in front, so it acts as if sTools were.
    @Test func aCenterNobodyTellsActsAsIfSToolsWereInFront() {
        let store = SettingsStore(directory: FileManager.default.temporaryDirectory.appending(path: "hotkey-scope-\(UUID().uuidString)"))
        store.save(HotkeySettings(isEnabled: true))
        let registrar = ScopeRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        let id = center.add(combo: cmd1, actions: [.toggle(.crosshair)])
        #expect(center.frontApp == .sTools)
        #expect(registrar.active == [id: cmd1])
    }

    @Test func theWatcherSortsTheAppInFrontByProcess() {
        let games = [minecraftInstance(pid: minecraftPID), minecraftInstance(pid: secondMinecraftPID)]
        #expect(HotkeyFrontAppWatcher.sort(sToolsPID, ownProcessID: sToolsPID, minecraft: games) == .sTools)
        #expect(HotkeyFrontAppWatcher.sort(minecraftPID, ownProcessID: sToolsPID, minecraft: games) == .minecraft)
        #expect(HotkeyFrontAppWatcher.sort(secondMinecraftPID, ownProcessID: sToolsPID, minecraft: games) == .minecraft)
        #expect(HotkeyFrontAppWatcher.sort(browserPID, ownProcessID: sToolsPID, minecraft: games) == .other)
        #expect(HotkeyFrontAppWatcher.sort(nil, ownProcessID: sToolsPID, minecraft: games) == .other)
        #expect(HotkeyFrontAppWatcher.sort(minecraftPID, ownProcessID: sToolsPID, minecraft: []) == .other)
        #expect(HotkeyFrontAppWatcher.sort(minecraftPID, ownProcessID: sToolsPID, minecraftProcesses: [minecraftPID]) == .minecraft)
        // The app's check asks NSWorkspace, which lists the Minecraft locator's Java processes too (reading it shows
        // nothing and asks for no permission).
        if let app = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated }) {
            #expect(HotkeyFrontAppWatcher.processIsRunning(app.processIdentifier))
        }
        #expect(!HotkeyFrontAppWatcher.processIsRunning(Int32.max))
    }

    @Test func theTypingNoteSaysWhoLosesTheKey() throws {
        let bareC = HotkeyCombo(keyCode: 8, modifiers: [])
        let everywhere = try #require(HotkeyWording.typingNote(for: bareC, scope: .everywhere))
        #expect(everywhere == HotkeyWording.typingNote(for: bareC))
        #expect(HotkeyWording.typingNote(for: bareC, scope: .sToolsAndMinecraft)
            == "While hotkeys are on, Minecraft never gets C, not even in its chat or seed field.")
        #expect(HotkeyWording.typingNote(for: cmd1, scope: .sToolsAndMinecraft) == nil)
        #expect(HotkeyWording.typingNote(for: f13, scope: .everywhere) == nil)

        let h = ScopeHarness()
        #expect(h.center.notes(for: bareC).map(\.text) == [HotkeyWording.typingNote(for: bareC, scope: .sToolsAndMinecraft)])
        h.center.scope = .everywhere
        #expect(h.center.notes(for: bareC).map(\.text) == [everywhere])
    }
}
