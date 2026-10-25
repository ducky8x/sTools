import Backdrop
import CoreGraphics
import Crosshair
import Foundation
import KeyRebinder
import NBBOverlay
import STDesign
@testable import STPlatform
import Synchronization
import Testing
import TimerOverlay
@testable import sTools

/// A permission prober whose answers the test sets; requests never show a system prompt.
final class FakeProber: PermissionProbing {
    private let statuses = Mutex<[Permission: PermissionStatus]>([:])
    private let requests = Mutex<[Permission]>([])
    private let reads = Mutex<[Permission: Int]>([:])

    init(accessibility: PermissionStatus = .granted) {
        statuses.withLock { $0[.accessibility] = accessibility }
    }

    var requested: [Permission] { requests.withLock { $0 } }

    func set(_ permission: Permission, _ status: PermissionStatus) {
        statuses.withLock { $0[permission] = status }
    }

    /// How many times `permission` was read.
    func readCount(_ permission: Permission) -> Int { reads.withLock { $0[permission] ?? 0 } }

    func status(for permission: Permission) -> PermissionStatus {
        reads.withLock { $0[permission, default: 0] += 1 }
        return statuses.withLock { $0[permission] ?? .denied }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        requests.withLock { $0.append(permission) }
        return status(for: permission)
    }
}

/// Never actually registers with the system; tests drive presses by calling `onPress` directly.
@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var registered: [UUID: HotkeyCombo] = [:]

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        registered[id] = combo
    }

    func unregister(id: UUID) {
        registered[id] = nil
    }
}

/// Records each hotkey confirmation instead of showing a panel.
@MainActor
final class FakeHotkeyHUD: HotkeyConfirmationPresenting {
    private(set) var presented: [(line: String, sealed: Bool, displayID: UInt32)] = []
    var lines: [String] { presented.map(\.line) }

    func present(_ line: String, sealed: Bool, on display: DisplayInfo) {
        presented.append((line, sealed, display.id))
    }
}

/// Captures what was copied instead of touching the real system pasteboard.
@MainActor
final class FakeClipboard: ClipboardWriting {
    private(set) var copiedText: String?
    func copy(_ text: String) { copiedText = text }
}

/// Records every `setEnabled` call.
@MainActor
final class FakeController: ToolController {
    private(set) var isEnabled = false
    private(set) var calls: [Bool] = []

    func setEnabled(_ enabled: Bool) {
        calls.append(enabled)
        isEnabled = enabled
    }
}

/// Runs nothing: every `karabiner_cli` command fails to start, as if Karabiner-Elements weren't installed.
struct FailingCommandRunner: CommandRunner {
    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        throw CommandRunnerError.launchFailed("Tests never run karabiner_cli.")
    }
}

/// URLs the permission center asked the system to open.
@MainActor
final class OpenedURLs {
    var urls: [URL] = []
}

/// The harness's one display, its main: display 1, where `fakeInstance()` puts Minecraft, but far outside every
/// real display, so a real controller switched on draws its panel where nothing shows on screen.
let harnessDisplay = DisplayInfo(
    id: 1, name: "Off screen", frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -9000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: true)

/// An `AppModel` wired to a temporary settings directory, fake permissions, a static Minecraft source and
/// `harnessDisplay`. The directory is removed when the harness goes away.
@MainActor
final class Harness {
    let model: AppModel
    let prober: FakeProber
    let source: StaticMinecraftWindowSource
    let store: SettingsStore
    let directory: URL
    let controllers: [ToolID: FakeController]
    /// Timer Overlay's real controller in both modes, on fakes: its overlay, guides and alarm never reach the
    /// screen or the speakers, and its clock moves only when a test moves it.
    let timer: TimerOverlayController
    let timerFakes = TimerFakes()
    let opened = OpenedURLs()
    let hotkeyRegistrar: any HotkeyRegistering
    let hotkeyHUD = FakeHotkeyHUD()
    /// The Key Rebinder's `karabiner.json` (with `withKeyRebinder`), in the harness's folder. Its folder exists;
    /// the file doesn't until a test writes it.
    let karabinerConfigURL: URL

    /// `prologueCompleted: false` launches as a first launch, with the introduction showing. `withKeyRebinder`
    /// adds a Key Rebinder over the harness's folder, connected like the app's: Karabiner-Elements reads as not
    /// installed and `karabiner_cli` never runs, so nothing touches `~/.config/karabiner`.
    ///
    /// `hotkeys` is the `hotkeys.json` the launch finds: an existing, empty list by default; nil for a new install,
    /// which starts with ⌘1–⌘5.
    init(accessibility: PermissionStatus = .granted, instances: [MinecraftInstance] = [],
         theme: STTheme = STTheme(), usesRealControllers: Bool = false, hotkeyRegistrar: any HotkeyRegistering = FakeHotkeyRegistrar(),
         prologueCompleted: Bool = true, withKeyRebinder: Bool = false, hotkeys: HotkeySettings? = HotkeySettings()) {
        self.hotkeyRegistrar = hotkeyRegistrar
        directory = FileManager.default.temporaryDirectory.appending(path: "sTools-app-\(UUID().uuidString)")
        karabinerConfigURL = directory.appending(path: "karabiner", directoryHint: .isDirectory).appending(path: "karabiner.json")
        prober = FakeProber(accessibility: accessibility)
        source = StaticMinecraftWindowSource(instances: instances)
        store = SettingsStore(directory: directory, debounce: .milliseconds(10))
        if prologueCompleted { store.save(AppState(prologueCompleted: true)) }
        if let hotkeys { store.save(hotkeys) }
        var fakes: [ToolID: FakeController] = [:]
        if !usesRealControllers {
            for tool in ToolID.allCases where tool.hasSwitch && tool != .timerOverlay { fakes[tool] = FakeController() }
        }
        controllers = fakes
        let opened = opened
        let permissions = PermissionCenter(prober: prober, openURL: { opened.urls.append($0) })
        let services = ToolServices(settings: store, displays: DisplayDirectory(screenProvider: { [harnessDisplay] }),
                                    minecraft: MinecraftLocator(source: source), permissions: permissions)
        timer = timerFakes.makeController(services: services, theme: theme)
        var all: [ToolID: any ToolController] = usesRealControllers
            ? [.nbbOverlay: NBBOverlayController(services: services, copies: NBBCopiesMonitor(scanner: NoNBBCopiesScanner())),
               .windowBackdrop: BackdropController(services: services),
               .crosshair: CrosshairController(services: services)]
            : fakes.mapValues { $0 as any ToolController }
        all[.timerOverlay] = timer
        var keyRebinder: KeyRebinderController?
        if withKeyRebinder {
            try? FileManager.default.createDirectory(at: karabinerConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            keyRebinder = KeyRebinderController(
                services: services, configURL: karabinerConfigURL,
                backupsDirectory: directory.appending(path: "Karabiner Backups", directoryHint: .isDirectory),
                cli: KarabinerCLI(runner: FailingCommandRunner(), cliURL: directory.appending(path: "no-karabiner_cli")),
                probes: KarabinerProbes(appBundleExists: { false }, cliVersion: { nil }, configReadable: { false }))
        }
        model = AppModel(services: services, theme: theme, sound: .silent, controllers: all, keyRebinder: keyRebinder,
                         hotkeyRegistrar: hotkeyRegistrar, hotkeyHUD: hotkeyHUD, loginItem: FakeLoginItem())
        model.pingNinjabrainBot = { false }
        model.evaluateKarabiner = { .notInstalled }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// One Minecraft window on display 1.
func fakeInstance(pid: Int32 = 100, version: String = "1.16.1", launched: TimeInterval = 1, displayID: UInt32? = 1) -> MinecraftInstance {
    let window = MinecraftWindow(windowNumber: UInt32(pid), processID: pid, title: "Minecraft* \(version)",
                                 frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    return MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: launched), displayID: displayID)
}

/// Waits (bounded) for `condition`, yielding to the main actor between checks.
///
/// The bound counts only time the Mac is awake (`SuspendingClock`). `ContinuousClock` keeps running while the Mac
/// sleeps, so a sleep in the middle of a test (an unattended run in Deep Idle with dark wakes) used up the whole bound
/// at once, and the wait gave up right after wake although what it waited for came a moment later.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

// MARK: - Timer Overlay fakes

/// Timer Overlay's injected parts, all fake: the timer target's own fakes are internal to its tests, so the app's
/// tests keep these. Nothing here shows a window, plays a sound or schedules a real wake.
@MainActor
final class TimerFakes {
    let clock = FakeTimerClock()
    let scheduler = FakeTimerScheduler()
    let presenter = FakeTimerPresenter()
    let guides = FakeRuleGuides()
    let alarm = FakeAlarm()
    let announcer = FakeTimerAnnouncer()

    init() { scheduler.clock = clock }

    func makeController(services: ToolServices, theme: STTheme) -> TimerOverlayController {
        TimerOverlayController(services: services, theme: theme, clock: clock, scheduler: scheduler,
                               activity: FakeTimerActivity(), wakeWatcher: FakeTimerWakeWatcher(),
                               presenter: presenter, guides: guides, alarm: alarm, announcer: announcer)
    }
}

@MainActor
final class FakeTimerClock: TimerClock {
    var time: TimeInterval = 1000
    func now() -> TimeInterval { time }
}

/// Holds every wake until a test fires it with `advance(by:)`.
@MainActor
final class FakeTimerScheduler: TimerScheduling {
    final class Wake: TimerScheduledWake {
        let due: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false
        init(due: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.action = action
        }
        func cancel() { isCancelled = true }
    }

    private(set) var wakes: [Wake] = []
    var clock: FakeTimerClock?

    var pending: [Wake] { wakes.filter { !$0.isCancelled } }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledWake {
        let wake = Wake(due: (clock?.time ?? 0) + delay, action: action)
        wakes.append(wake)
        return wake
    }
}

@MainActor
final class FakeTimerActivity: TimerActivity {
    func begin() {}
    func end() {}
}

@MainActor
final class FakeTimerWakeWatcher: TimerWakeWatching {
    func start(_ handler: @escaping @MainActor () -> Void) {}
    func stop() {}
}

/// Records what the controller asked of the overlay, including whether each motion was reduced.
@MainActor
final class FakeTimerPresenter: TimerOverlayPresenting {
    private(set) var isShowing = false
    private(set) var plateFrame: CGRect?
    private(set) var popIns: [Bool] = []
    private(set) var pulses: [Bool] = []
    private(set) var popOuts: [Bool] = []
    private(set) var contents: [TimerOverlayContent] = []

    /// Every motion asked for, as whether it was reduced.
    var motions: [Bool] { popIns + pulses + popOuts }

    func plateSize(for content: TimerOverlayContent, settings: TimerOverlaySettings) -> CGSize {
        CGSize(width: 120, height: 48)
    }

    func popIn(_ content: TimerOverlayContent, settings: TimerOverlaySettings, plateFrame: CGRect, displayFrame: CGRect,
               reduceMotion: Bool) {
        isShowing = true
        self.plateFrame = plateFrame
        popIns.append(reduceMotion)
        contents.append(content)
    }

    func update(_ content: TimerOverlayContent) { contents.append(content) }
    func update(settings: TimerOverlaySettings) {}
    func move(plateFrame: CGRect, displayFrame: CGRect) { self.plateFrame = plateFrame }
    func pulse(reduceMotion: Bool) { pulses.append(reduceMotion) }

    func popOut(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        popOuts.append(reduceMotion)
        isShowing = false
        plateFrame = nil
        completion()
    }

    func setPlacementMode(_ isOn: Bool, onDragChanged: @escaping @MainActor (CGSize) -> Void,
                          onDragEnded: @escaping @MainActor () -> Void) {}
}

@MainActor
final class FakeRuleGuides: RuleGuidesPresenting {
    func show(_ zones: RuleZones, on display: DisplayInfo) {}
    func markCovered(_ kinds: [RuleZones.Kind], plateFrame: CGRect) {}
    func hide() {}
}

/// Never plays anything; counts what it was asked to play.
@MainActor
final class FakeAlarm: AlarmPlaying {
    private(set) var isPlaying = false
    var onRenderedBuffer: (@Sendable (AlarmRenderedBuffer) -> Void)?
    private(set) var rings = 0

    func ring(_ sound: URL, volume: Double, schedule: AlarmSchedule,
              onRing: @escaping @MainActor (_ index: Int) -> Void, onEnd: @escaping @MainActor () -> Void) {
        rings += 1
        isPlaying = true
    }

    func playCue(_ cue: AlarmSchedule.Cue, volume: Double) {}
    func preview(_ sound: URL, volume: Double, rings: Int, onEnd: @escaping @MainActor () -> Void) {}
    func stop() { isPlaying = false }
}

@MainActor
final class FakeTimerAnnouncer: TimerAnnouncing {
    private(set) var announcements: [TimerAnnouncement] = []
    func announce(_ announcement: TimerAnnouncement) { announcements.append(announcement) }
}
