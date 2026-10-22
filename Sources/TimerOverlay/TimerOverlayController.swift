import Foundation
import Observation
import STDesign
import STPlatform

/// What a Start-timer press did (spec 5.6.2), so the app can confirm it (plan decision 5).
public enum TimerPressResult: Equatable, Sendable {
    /// It started, restarted, paused, resumed or cancelled the timer, or silenced the alarm. The overlay itself
    /// confirms it: the app adds no sound and no line.
    case acted
    /// The press table says to ignore it here (as Advanced's "is ignored" does), or a double press found nothing to
    /// cancel.
    case ignored
    /// The tool is off and couldn't be switched on: Accessibility is missing (R10). The app shows
    /// "Timer Overlay needs Accessibility" without the seal.
    case couldNotStart
}

/// Owns Timer Overlay (spec 5.6): one countdown, started by one key, that pops up over the game, counts down,
/// rings and leaves by itself.
@MainActor
@Observable
public final class TimerOverlayController: ToolController {
    /// The page's Test runs this long (spec 5.6.3).
    public static let testRunSeconds = 5

    public private(set) var isEnabled = false

    /// Switches the tool on through the app (its sidebar switch and the Accessibility rule, R10); returns whether
    /// it is on afterwards. Without it, the controller switches itself on.
    @ObservationIgnored public var requestEnable: (@MainActor () -> Bool)?

    public var settings: TimerOverlaySettings {
        didSet {
            guard settings != oldValue else { return }
            services.settings.save(settings)
        }
    }

    /// Where the timer is in a run.
    public private(set) var phase: TimerPhase = .idle
    /// Whether the run under way is the page's 5-second Test.
    public private(set) var isTestRun = false
    /// What the overlay shows now; the page's preview plate draws it too. While nothing counts it's the saved
    /// duration. It changes once per shown change of the time.
    public private(set) var content: TimerOverlayContent
    /// The sidebar's, Home's and the Dock's words. It changes at most once a second.
    public private(set) var status: TimerStatus = .off
    /// Whether the page's Preview is playing.
    public private(set) var isPreviewing = false

    @ObservationIgnored let services: ToolServices
    @ObservationIgnored let theme: STTheme
    @ObservationIgnored let clock: any TimerClock
    @ObservationIgnored let scheduler: any TimerScheduling
    @ObservationIgnored let engine: TimerEngine
    @ObservationIgnored let presenter: any TimerOverlayPresenting
    @ObservationIgnored let guides: any RuleGuidesPresenting
    @ObservationIgnored let alarm: any AlarmPlaying
    @ObservationIgnored let announcer: any TimerAnnouncing
    /// The owner's alarm files: `Sounds/` in the settings folder.
    @ObservationIgnored let ownSounds: OwnSounds
    /// Where the macOS sounds are. Tests point it elsewhere.
    @ObservationIgnored var macOSSoundsDirectory = AlarmSound.systemSoundsDirectory
    @ObservationIgnored var policy = PressPolicy()

    /// `theme` is the app's: the overlay reads Reduce animations and Increase Contrast from it, because an overlay
    /// panel's own SwiftUI root only sees the fallback theme. The rest default to the live ones; tests pass fakes.
    /// The live presenter and alarm player share the controller's clock and scheduler, so one clock measures
    /// everything.
    public init(
        services: ToolServices,
        theme: STTheme,
        clock: any TimerClock = MonotonicClock(),
        scheduler: any TimerScheduling = DispatchTimerScheduler(),
        activity: any TimerActivity = ProcessTimerActivity(),
        wakeWatcher: any TimerWakeWatching = WorkspaceWakeWatcher(),
        presenter: (any TimerOverlayPresenting)? = nil,
        guides: (any RuleGuidesPresenting)? = nil,
        alarm: (any AlarmPlaying)? = nil,
        announcer: (any TimerAnnouncing)? = nil
    ) {
        self.services = services
        self.theme = theme
        self.clock = clock
        self.scheduler = scheduler
        self.presenter = presenter ?? TimerOverlayPresenter(theme: theme, scheduler: scheduler, clock: clock)
        self.guides = guides ?? RuleGuidesPresenter(theme: theme)
        self.alarm = alarm ?? AlarmPlayer(clock: clock, scheduler: scheduler)
        self.announcer = announcer ?? TimerAnnouncer()
        ownSounds = OwnSounds(settingsDirectory: services.settings.directory)
        let loaded = services.settings.load(TimerOverlaySettings.self)
        settings = loaded
        engine = TimerEngine(duration: TimeInterval(loaded.durationSeconds), clock: clock, scheduler: scheduler,
                             activity: activity, wakeWatcher: wakeWatcher)
        content = TimerOverlayContent(text: ClockFormat.string(seconds: loaded.durationSeconds))
    }

    /// Whether Accessibility is granted: without it the tool is fully off (spec 5.6.1, R10), and the page's Start
    /// and Test are disabled.
    public var isAvailable: Bool { services.permissions.status(.accessibility) == .granted }

    /// Whether the page's Test can run now: not while a countdown runs or is paused (spec 5.6.3).
    public var canRunTest: Bool { phase != .counting && phase != .paused }

    // MARK: - The switch

    /// Off cancels a run, hides the overlay and ends placement mode.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
    }

    /// Every setting back to its default. The owner's files in `Sounds/` stay.
    public func resetToDefault() {
        settings = TimerOverlaySettings.defaultValue
    }

    // MARK: - The page's controls

    /// Starts a countdown of the saved duration, from any phase, switching the tool on first through
    /// `requestEnable` when it's off. False when it couldn't.
    @discardableResult
    public func start() -> Bool {
        false
    }

    /// Pauses a counting countdown.
    public func pause() {}

    /// Resumes a paused countdown.
    public func resume() {}

    /// Cancels the run and hides the overlay, stopping the alarm if it rings.
    public func cancel() {}

    /// The page's Test: a 5-second run with the full pop-up, alarm and exit, which leaves the saved duration alone.
    /// It switches the tool on first, as Start does, and does nothing while a countdown runs or is paused.
    @discardableResult
    public func runTest() -> Bool {
        false
    }

    // MARK: - The key

    /// A Start-timer press, from the app's hotkey. Stamped with the controller's clock, so the 0.4 s double press
    /// and the 1 s hold are measured on the countdown's own clock. While the tool is off it asks `requestEnable`
    /// first, as the key turns the tool on (spec 5.6.2).
    @discardableResult
    public func press() -> TimerPressResult {
        .ignored
    }

    /// The Start-timer key is up again, for the hold-to-cancel gesture.
    public func release() {}

    // MARK: - Sounds, for the page

    /// Everything the alarm picker lists: the macOS sounds this Mac has, sTools' alarms, then the owner's files.
    public var sounds: [AlarmSound] {
        AlarmSound.all(own: ownSounds, macOSDirectory: macOSSoundsDirectory)
    }

    /// Copies one of the owner's sound files into `Sounds/` and makes it the alarm. Throws `OwnSoundsError`.
    @discardableResult
    public func addSound(from file: URL) throws -> AlarmSound {
        try ownSounds.add(file)
    }

    /// Deletes one of the owner's files from `Sounds/`. The alarm goes back to Ping when it was that one.
    public func removeSound(_ sound: AlarmSound) throws {
        try ownSounds.remove(sound)
    }

    /// Plays `sound`, or the alarm's own sound, the way the alarm would, at the alarm's volume and rings.
    public func preview(_ sound: AlarmSound? = nil) {}

    /// Stops the page's Preview.
    public func stopPreview() {}

    /// The page's note when the alarm's sound is gone, such as a deleted file: Ping plays instead (decision 12).
    public var missingSoundNote: String? { nil }

    // MARK: - The rule note

    /// Whether the page shows the rule notice: "Rule note on the page" is the line plus the notice, the tool has
    /// been turned on, and the notice hasn't been dismissed.
    public var showsRuleNotice: Bool { false }

    /// Dismisses the rule notice for good.
    public func dismissRuleNotice() {
        settings.ruleNoticeDismissed = true
    }
}
