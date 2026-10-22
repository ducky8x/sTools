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
///
/// - Presses become actions through `PressPolicy`, stamped with the controller's own clock.
/// - `TimerEngine` runs the countdown; the presenter shows the overlay, the alarm player rings it and plays the cues
///   before zero, at `AlarmSchedule`'s times.
/// - Motion: every pop-in, pop-out and pulse hands the presenter `theme.reduceMotion` as it starts, so Reduce
///   animations (or macOS's Reduce motion) stops it whenever it's on.
/// - Cost (spec 9.3): an idle timer runs nothing. There's no panel, no scheduled wake, no process activity, no audio
///   engine and no observer of Minecraft, the displays or wake until a countdown starts or placement mode is on.
///   While counting, the overlay and `content` change once per shown change, and `status` at most once a second.
@MainActor
@Observable
public final class TimerOverlayController: ToolController {
    /// The page's Test runs this long (spec 5.6.3).
    public static let testRunSeconds = 5
    /// How long a paused overlay stays up with "While paused: hide after 3 s" (Timer round C2).
    public static let pausedHideDelay: TimeInterval = 3
    /// The length the alarm's rings are spaced by when its file can't be read: Ping's.
    static let assumedSoundLength: TimeInterval = 1.5

    public private(set) var isEnabled = false

    /// Switches the tool on through the app (its sidebar switch and the Accessibility rule, R10); returns whether
    /// it is on afterwards. Without it, the controller switches itself on.
    @ObservationIgnored public var requestEnable: (@MainActor () -> Bool)?

    public var settings: TimerOverlaySettings {
        didSet {
            guard settings != oldValue else { return }
            services.settings.save(settings)
            settingsChanged(from: oldValue)
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
    /// Whether the tool has been switched on since launch, for the rule notice.
    private(set) var hasBeenTurnedOn = false
    /// Bumped when the owner's files change, so the sound list and the missing-file note are read again.
    private var soundsGeneration = 0

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

    // The overlay
    /// Whether the overlay is up: popped in, and not popped out since.
    @ObservationIgnored private(set) var isOverlayUp = false
    /// What the presenter was last given, so it's given each shown change once.
    @ObservationIgnored private var shownContent: TimerOverlayContent?
    /// Where the plate was last put: its offset on a display. It moves only when either changes.
    @ObservationIgnored var placedAt: (offset: TimerPlacement.Offset, displayFrame: CGRect)?
    /// Counts pop-ins and pop-outs, so a pop-out's completion that's been overtaken does nothing.
    @ObservationIgnored private var exitGeneration = 0
    /// While paused, the overlay has hidden ("While paused").
    @ObservationIgnored private var isPausedHidden = false

    // Placement mode (see the extension)
    @ObservationIgnored var drag: PlacementDrag?
    /// The plate covers a rule zone while it's dragged.
    @ObservationIgnored var showsDangerEdge = false

    // The run
    @ObservationIgnored private var leaveWake: (any TimerScheduledWake)?
    @ObservationIgnored private var flashWake: (any TimerScheduledWake)?
    @ObservationIgnored private var pausedHideWake: (any TimerScheduledWake)?
    /// The time left when the cues were last checked.
    @ObservationIgnored private var cueRemaining: TimeInterval = 0
    /// Whether Minecraft has been in front since the countdown started (plan decision 8).
    @ObservationIgnored private var minecraftWasFront = false
    /// Paused by "Pause while Minecraft isn't focused", so Minecraft coming back resumes it.
    @ObservationIgnored private var isAutoPaused = false

    // The alarm
    /// Whether the run's alarm is playing.
    @ObservationIgnored private var isRinging = false
    /// Counts alarms, cues and stops, so a callback from one that's been stopped or replaced does nothing.
    @ObservationIgnored private var alarmGeneration = 0
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var alarmSchedule: AlarmSchedule?

    // Watching Minecraft and the displays
    /// Whether the controller follows Minecraft and the displays: only while a run is live or placement mode is on.
    @ObservationIgnored private(set) var isWatchingEnvironment = false
    @ObservationIgnored private var watchGeneration = 0
    /// How many times a change of Minecraft or the displays reached the controller. For tests.
    @ObservationIgnored private(set) var environmentChanges = 0

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
        var loaded = services.settings.load(TimerOverlaySettings.self)
        // Placement mode never outlasts a launch: the tool starts off, so no plate is up (plan decision 13).
        if loaded.placementModeEnabled {
            loaded.placementModeEnabled = false
            services.settings.save(loaded)
        }
        settings = loaded
        engine = TimerEngine(duration: TimeInterval(loaded.durationSeconds), clock: clock, scheduler: scheduler,
                             activity: activity, wakeWatcher: wakeWatcher)
        content = TimerOverlayContent(text: "")
        engine.showsTenths = loaded.showsTenths
        engine.showsOvertime = loaded.atZero == .overtime
        engine.onTick = { [weak self] now in self?.engineTicked(at: now) }
        engine.onFinish = { [weak self] now in self?.engineFinished(at: now) }
        content = makeContent(at: clock.now())
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
        if enabled {
            hasBeenTurnedOn = true
            if settings.placementModeEnabled { placementSettingChanged() }
            updateOverlay()
        } else {
            policy.reset()
            if settings.placementModeEnabled {
                settings.placementModeEnabled = false
                services.settings.save(settings)
            }
            endRun()
        }
        refreshStatus(at: clock.now())
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
        guard switchOn() else { return false }
        policy.reset()
        return beginRun(isTest: false)
    }

    /// Pauses a counting countdown.
    public func pause() {
        policy.reset()
        pauseRun()
    }

    /// Resumes a paused countdown.
    public func resume() {
        policy.reset()
        resumeRun()
    }

    /// Cancels the run and hides the overlay, stopping the alarm if it rings.
    public func cancel() {
        guard phase != .idle, phase != .leaving else { return }
        policy.reset()
        endRun()
    }

    /// The page's Test: a 5-second run with the full pop-up, alarm and exit, which leaves the saved duration alone.
    /// It switches the tool on first, as Start does, and does nothing while a countdown runs or is paused.
    @discardableResult
    public func runTest() -> Bool {
        guard canRunTest, switchOn() else { return false }
        policy.reset()
        return beginRun(isTest: true)
    }

    // MARK: - The key

    /// A Start-timer press, from the app's hotkey. Stamped with the controller's clock, so the 0.4 s double press
    /// and the 1 s hold are measured on the countdown's own clock. While the tool is off it asks `requestEnable`
    /// first, as the key turns the tool on (spec 5.6.2).
    @discardableResult
    public func press() -> TimerPressResult {
        let now = clock.now()
        guard isEnabled || switchOn() else { return .couldNotStart }
        let action = policy.handle(.press, at: now, phase: phase, settings: settings)
        return perform(action) ? .acted : .ignored
    }

    /// The Start-timer key is up again, for the hold-to-cancel gesture.
    public func release() {
        let now = clock.now()
        guard isEnabled else { return }
        perform(policy.handle(.release, at: now, phase: phase, settings: settings))
    }

    /// Carries out what the press table decided. False when it did nothing.
    @discardableResult
    private func perform(_ action: PressPolicy.Action) -> Bool {
        switch action {
        case .start, .restart, .newCountdown:
            // The key always means the saved duration, even during Test (plan decision 9).
            return beginRun(isTest: false)
        case .cancel, .silenceAndHide:
            guard phase != .idle, phase != .leaving else { return false }
            endRun()
            return true
        case .pause:
            return pauseRun()
        case .resume:
            return resumeRun()
        case .ignore:
            return false
        }
    }

    /// Switches the tool on when it's off, through the app when it can. Whether it's on afterwards.
    private func switchOn() -> Bool {
        guard !isEnabled else { return true }
        if let requestEnable {
            guard requestEnable() else { return false }
            if !isEnabled { setEnabled(true) }
        } else {
            setEnabled(true)
        }
        return isEnabled
    }

    // MARK: - A run

    /// Starts a countdown from any phase: the saved duration, or Test's 5 seconds.
    @discardableResult
    private func beginRun(isTest: Bool) -> Bool {
        let length = isTest ? TimeInterval(Self.testRunSeconds) : nil
        guard engine.start(length: length) else { return false }
        stopRunWakes()
        stopRunSounds()
        if phase == .leaving {
            // The new pop-in releases the leaving panel, and its exit never completes.
            isOverlayUp = false
        }
        phase = .counting
        isTestRun = isTest
        isAutoPaused = false
        isPausedHidden = false
        minecraftWasFront = services.minecraft.active?.isFrontmost == true
        cueRemaining = engine.countdown.length
        let now = clock.now()
        refreshContent(at: now)
        refreshStatus(at: now)
        updateOverlay()
        announcer.announce(.started(seconds: Int(engine.countdown.length.rounded())))
        return true
    }

    @discardableResult
    private func pauseRun() -> Bool {
        guard phase == .counting, engine.pause() else { return false }
        enterPause()
        return true
    }

    @discardableResult
    private func resumeRun() -> Bool {
        guard phase == .paused, engine.resume() else { return false }
        isAutoPaused = false
        leavePause()
        return true
    }

    private func enterPause() {
        phase = .paused
        isPausedHidden = settings.whilePaused == .hideAtOnce
        if settings.whilePaused == .hideAfterDelay {
            pausedHideWake = scheduler.schedule(after: Self.pausedHideDelay) { [weak self] in
                guard let self, self.phase == .paused else { return }
                self.pausedHideWake = nil
                self.isPausedHidden = true
                self.updateOverlay()
            }
        }
        let now = clock.now()
        refreshContent(at: now)
        refreshStatus(at: now)
        updateOverlay()
    }

    private func leavePause() {
        pausedHideWake?.cancel()
        pausedHideWake = nil
        isPausedHidden = false
        phase = .counting
        let now = clock.now()
        refreshContent(at: now)
        refreshStatus(at: now)
        updateOverlay()
    }

    /// Ends the run (a cancel, the leave time, switching off): stops the alarm, and the overlay leaves the way it
    /// came. Once it has left, the run is cancelled, which ends the process activity. In placement mode the plate
    /// stays and shows the sample again.
    private func endRun() {
        stopRunWakes()
        stopRunSounds()
        guard isOverlayUp, !isPlacing else {
            finishRun()
            return
        }
        phase = .leaving
        refreshStatus(at: clock.now())
        isOverlayUp = false
        shownContent = nil
        exitGeneration += 1
        let generation = exitGeneration
        presenter.popOut(reduceMotion: theme.reduceMotion) { [weak self] in
            guard let self, self.exitGeneration == generation, self.phase == .leaving else { return }
            self.finishRun()
        }
        updateWatching()
    }

    /// Back to idle, with nothing scheduled, held or playing for the run.
    private func finishRun() {
        stopRunWakes()
        phase = .idle
        isTestRun = false
        isAutoPaused = false
        isPausedHidden = false
        alarmSchedule = nil
        engine.cancel()
        let now = clock.now()
        refreshContent(at: now)
        refreshStatus(at: now)
        updateOverlay()
    }

    private func stopRunWakes() {
        leaveWake?.cancel()
        leaveWake = nil
        flashWake?.cancel()
        flashWake = nil
        pausedHideWake?.cancel()
        pausedHideWake = nil
    }

    /// Stops the run's alarm, or a cue, but never the page's Preview.
    private func stopRunSounds() {
        alarmGeneration += 1
        isRinging = false
        if !isPreviewing, alarm.isPlaying { alarm.stop() }
    }

    // MARK: - The engine

    private func engineTicked(at now: TimeInterval) {
        switch phase {
        case .counting:
            playDueCues(at: now)
            refreshContent(at: now)
            refreshStatus(at: now)
        case .ringing, .lingering:
            // Overtime counting up.
            refreshContent(at: now)
        case .idle, .paused, .leaving:
            break
        }
    }

    /// Zero: the time noticed, zero itself or the wake after the Mac slept past it (plan decision 15).
    private func engineFinished(at now: TimeInterval) {
        guard phase == .counting else { return }
        phase = .ringing
        isAutoPaused = false
        refreshContent(at: now)
        refreshStatus(at: now)
        announcer.announce(.timesUp)
        ring()
        updateOverlay()
    }

    private func playDueCues(at now: TimeInterval) {
        let remaining = engine.countdown.remaining(at: now)
        let cues = AlarmSchedule.cues(settings: settings, length: engine.countdown.length)
        let due = AlarmSchedule.cuesDue(cues, from: cueRemaining, to: remaining)
        cueRemaining = remaining
        guard let cue = due.last else { return }
        endPreview()
        alarmGeneration += 1
        alarm.playCue(cue.cue, volume: settings.volume)
    }

    // MARK: - The alarm

    /// Rings the alarm from now, and schedules the overlay's leave by `AlarmSchedule`.
    private func ring() {
        let resolution = AlarmSound.resolve(settings.soundID, own: ownSounds, macOSDirectory: macOSSoundsDirectory)
        let schedule = AlarmSchedule(soundLength: resolution.sound.length ?? Self.assumedSoundLength, settings: settings)
        alarmSchedule = schedule
        endPreview()
        alarmGeneration += 1
        let generation = alarmGeneration
        isRinging = true
        alarm.ring(resolution.sound.url, volume: settings.volume, schedule: schedule,
                   onRing: { [weak self] index in self?.alarmRang(index, generation: generation) },
                   onEnd: { [weak self] in self?.alarmEnded(generation: generation) })
        leaveWake = scheduler.schedule(after: schedule.leaveTime) { [weak self] in
            guard let self else { return }
            self.leaveWake = nil
            guard self.phase == .ringing || self.phase == .lingering else { return }
            self.endRun()
        }
    }

    /// A ring starts: one pulse, or the first of its quick flashes with the rest scheduled after it.
    private func alarmRang(_ index: Int, generation: Int) {
        guard generation == alarmGeneration, phase == .ringing, let schedule = alarmSchedule,
              schedule.ringStarts.indices.contains(index)
        else { return }
        let start = schedule.ringStarts[index]
        let next = index + 1 < schedule.ringStarts.count ? schedule.ringStarts[index + 1] : .infinity
        guard schedule.pulseTimes.contains(where: { abs($0 - start) < 1e-9 }) else { return }
        pulse()
        let followUps = schedule.pulseTimes.filter { $0 > start + 1e-9 && $0 < next - 1e-9 }.map { $0 - start }
        scheduleFlashes(followUps, after: 0, generation: generation)
    }

    /// Quick flashes after a ring's first, one wake at a time.
    private func scheduleFlashes(_ offsets: [TimeInterval], after elapsed: TimeInterval, generation: Int) {
        flashWake?.cancel()
        flashWake = nil
        guard let first = offsets.first else { return }
        flashWake = scheduler.schedule(after: first - elapsed) { [weak self] in
            guard let self, generation == self.alarmGeneration,
                  self.phase == .ringing || self.phase == .lingering
            else { return }
            self.flashWake = nil
            self.pulse()
            self.scheduleFlashes(Array(offsets.dropFirst()), after: first, generation: generation)
        }
    }

    private func pulse() {
        guard isOverlayUp else { return }
        presenter.pulse(reduceMotion: theme.reduceMotion)
    }

    private func alarmEnded(generation: Int) {
        guard generation == alarmGeneration else { return }
        isRinging = false
        if phase == .ringing { phase = .lingering }
    }

    // MARK: - Sounds, for the page

    /// Everything the alarm picker lists: the macOS sounds this Mac has, sTools' alarms, then the owner's files.
    public var sounds: [AlarmSound] {
        _ = soundsGeneration
        return AlarmSound.all(own: ownSounds, macOSDirectory: macOSSoundsDirectory)
    }

    /// Copies one of the owner's sound files into `Sounds/` and makes it the alarm. Throws `OwnSoundsError`.
    @discardableResult
    public func addSound(from file: URL) throws -> AlarmSound {
        let sound = try ownSounds.add(file)
        soundsGeneration += 1
        settings.soundID = sound.id
        return sound
    }

    /// Deletes one of the owner's files from `Sounds/`. The alarm goes back to Ping when it was that one.
    public func removeSound(_ sound: AlarmSound) throws {
        try ownSounds.remove(sound)
        soundsGeneration += 1
        if settings.soundID == sound.id { settings.soundID = AlarmSound.fallbackID }
    }

    /// Plays `sound`, or the alarm's own sound, the way the alarm would, at the alarm's volume and rings. It
    /// replaces a ringing alarm, which then counts as ended.
    public func preview(_ sound: AlarmSound? = nil) {
        let chosen = sound
            ?? AlarmSound.resolve(settings.soundID, own: ownSounds, macOSDirectory: macOSSoundsDirectory).sound
        if isRinging {
            alarmGeneration += 1
            isRinging = false
            if phase == .ringing { phase = .lingering }
        }
        previewGeneration += 1
        let generation = previewGeneration
        isPreviewing = true
        alarm.preview(chosen.url, volume: settings.volume, rings: settings.rings) { [weak self] in
            guard let self, generation == self.previewGeneration else { return }
            self.isPreviewing = false
        }
    }

    /// Stops the page's Preview.
    public func stopPreview() {
        guard isPreviewing else { return }
        endPreview()
        alarm.stop()
    }

    /// Forgets the Preview, as when the alarm or a cue replaces it.
    private func endPreview() {
        previewGeneration += 1
        if isPreviewing { isPreviewing = false }
    }

    /// The page's note when the alarm's sound is gone, such as a deleted file: Ping plays instead (decision 12).
    /// Placeholder wording for M9.
    public var missingSoundNote: String? {
        _ = soundsGeneration
        let resolution = AlarmSound.resolve(settings.soundID, own: ownSounds, macOSDirectory: macOSSoundsDirectory)
        guard resolution.isMissing else { return nil }
        let name = AlarmSound.parse(settings.soundID).map { parsed in
            parsed.source == .file ? AlarmSound.ownFile(named: parsed.name, in: ownSounds.directory).title : parsed.name
        } ?? settings.soundID
        return "\u{201C}\(name)\u{201D} is missing, so \(resolution.sound.title) plays instead."
    }

    // MARK: - The rule note

    /// Whether the page shows the rule notice: "Rule note on the page" is the line plus the notice, the tool has
    /// been turned on, and the notice hasn't been dismissed.
    public var showsRuleNotice: Bool {
        settings.ruleNote == .lineAndNotice && !settings.ruleNoticeDismissed && hasBeenTurnedOn
    }

    /// Dismisses the rule notice for good.
    public func dismissRuleNotice() {
        settings.ruleNoticeDismissed = true
    }

    // MARK: - Settings

    private func settingsChanged(from old: TimerOverlaySettings) {
        engine.duration = TimeInterval(settings.durationSeconds)
        engine.showsTenths = settings.showsTenths
        engine.showsOvertime = settings.atZero == .overtime
        if settings.placementModeEnabled != old.placementModeEnabled { placementSettingChanged() }
        if isOverlayUp { presenter.update(settings: settings) }
        if phase == .paused, settings.whilePaused != old.whilePaused {
            pausedHideWake?.cancel()
            pausedHideWake = nil
            isPausedHidden = settings.whilePaused == .hideAtOnce
        }
        let now = clock.now()
        refreshContent(at: now)
        refreshStatus(at: now)
        applyFocusPause()
        updateOverlay()
    }

    // MARK: - What it shows

    /// The content for the phase at `now`.
    func makeContent(at now: TimeInterval) -> TimerOverlayContent {
        let countdown = engine.countdown
        let text: String
        let state: TimerOverlayContent.State
        let progress: Double
        switch phase {
        case .idle:
            // The saved duration: the sample the page and placement mode show.
            let seconds = max(settings.durationSeconds, 1)
            text = ClockFormat.string(remaining: TimeInterval(seconds), format: settings.timeFormat,
                                      tenths: settings.showsTenths)
            state = TimerOverlayContent.countingState(shownSeconds: seconds, settings: settings)
            progress = 1
        case .counting, .paused:
            text = ClockFormat.string(remaining: countdown.remaining(at: now), format: settings.timeFormat,
                                      tenths: settings.showsTenths)
            state = phase == .paused ? .paused
                : TimerOverlayContent.countingState(shownSeconds: countdown.displaySeconds(at: now), settings: settings)
            progress = countdown.steppedProgress(at: now)
        case .ringing, .lingering, .leaving:
            text = ClockFormat.atZero(settings.atZero, word: settings.atZeroWord,
                                      sinceZero: countdown.timeSinceZero(at: now), format: settings.timeFormat,
                                      tenths: settings.showsTenths)
            state = .timesUp
            progress = 0
        }
        return TimerOverlayContent(text: text, state: state, steppedProgress: progress, settings: settings,
                                   showsDangerEdge: showsDangerEdge)
    }

    /// Brings `content` and the overlay up to date, telling the presenter only about a real change. On the way out
    /// the overlay keeps what it showed.
    func refreshContent(at now: TimeInterval) {
        guard phase != .leaving else { return }
        let fresh = makeContent(at: now)
        if fresh != content { content = fresh }
        if isOverlayUp, fresh != shownContent {
            presenter.update(fresh)
            shownContent = fresh
        }
    }

    private func refreshStatus(at now: TimeInterval) {
        let fresh: TimerStatus
        if !isEnabled {
            fresh = .off
        } else {
            switch phase {
            case .idle, .leaving: fresh = .ready
            case .counting: fresh = .counting(secondsLeft: engine.countdown.displaySeconds(at: now))
            case .paused: fresh = .paused(secondsLeft: engine.countdown.displaySeconds(at: now))
            case .ringing, .lingering: fresh = .timesUp
            }
        }
        if fresh != status { status = fresh }
    }

    // MARK: - The overlay

    /// Whether the overlay should be up now.
    private var wantsOverlay: Bool {
        guard isEnabled else { return false }
        if isPlacing { return true }
        switch phase {
        case .idle, .leaving: return false
        case .counting, .ringing, .lingering: return isVisibleForFocus
        case .paused: return isVisibleForFocus && !isPausedHidden
        }
    }

    /// "Only while Minecraft is focused", once Minecraft has been in front since the countdown started (plan
    /// decision 8). Test ignores it.
    private var isVisibleForFocus: Bool {
        guard settings.visibleOnlyWhileMinecraftFocused, !isTestRun, minecraftWasFront else { return true }
        return services.minecraft.active?.isFrontmost == true
    }

    /// Pops the overlay in or out, or moves it, to match what it should do now; then follows Minecraft and the
    /// displays only as long as that's needed.
    func updateOverlay() {
        if phase != .leaving {
            let wanted = wantsOverlay
            if wanted, !isOverlayUp {
                popIn()
            } else if !wanted, isOverlayUp {
                popOutForNow()
            } else if wanted {
                placeIfMoved()
            }
        }
        updateWatching()
    }

    private func popIn() {
        guard let display = targetDisplay() else { return }
        let now = clock.now()
        let fresh = makeContent(at: now)
        if fresh != content { content = fresh }
        let offset = TimerPlacement.Offset(settings)
        let size = presenter.plateSize(for: fresh, settings: settings)
        let frame = TimerPlacement.plateFrame(size: size, offset: offset, on: display)
        exitGeneration += 1
        presenter.popIn(fresh, settings: settings, plateFrame: frame, displayFrame: display.frame,
                        reduceMotion: theme.reduceMotion)
        isOverlayUp = true
        shownContent = fresh
        placedAt = (offset, display.frame)
    }

    /// Hides the overlay without ending the run: paused, or Minecraft isn't focused.
    private func popOutForNow() {
        isOverlayUp = false
        shownContent = nil
        exitGeneration += 1
        presenter.popOut(reduceMotion: theme.reduceMotion) {}
    }

    /// Moves the plate when its offset or display changed: typed X/Y, another display, or Minecraft moving.
    private func placeIfMoved() {
        guard drag == nil, let display = targetDisplay() else { return }
        let offset = TimerPlacement.Offset(settings)
        if let placedAt, placedAt.offset == offset, placedAt.displayFrame == display.frame { return }
        let size = presenter.plateFrame?.size ?? presenter.plateSize(for: content, settings: settings)
        presenter.move(plateFrame: TimerPlacement.plateFrame(size: size, offset: offset, on: display),
                       displayFrame: display.frame)
        placedAt = (offset, display.frame)
    }

    /// The display the overlay goes on: Minecraft's, the chosen one, else the main display.
    func targetDisplay() -> DisplayInfo? {
        TimerPlacement.display(for: settings, minecraftDisplayID: services.minecraft.active?.displayID,
                               in: services.displays.displays)
    }

    // MARK: - Minecraft and the displays

    /// Follows Minecraft and the displays while a run is live or placement mode is on, and not otherwise.
    private func updateWatching() {
        let wanted = isEnabled && (isPlacing || [.counting, .paused, .ringing, .lingering].contains(phase))
        guard wanted != isWatchingEnvironment else { return }
        isWatchingEnvironment = wanted
        watchGeneration += 1
        if wanted { watchEnvironment(generation: watchGeneration) }
    }

    /// One observation at a time, armed again after each change while it's still wanted. Once it isn't, the last
    /// one is left to lapse: its change does nothing.
    private func watchEnvironment(generation: Int) {
        withObservationTracking {
            _ = services.minecraft.active
            _ = services.displays.displays
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isWatchingEnvironment, self.watchGeneration == generation else { return }
                self.environmentChanged()
                if self.isWatchingEnvironment, self.watchGeneration == generation {
                    self.watchEnvironment(generation: generation)
                }
            }
        }
    }

    private func environmentChanged() {
        environmentChanges += 1
        if services.minecraft.active?.isFrontmost == true { minecraftWasFront = true }
        placementEnvironmentChanged()
        applyFocusPause()
        updateOverlay()
    }

    /// "Pause while Minecraft isn't focused", once Minecraft has been in front since the countdown started (plan
    /// decision 8). Test and placement mode ignore it.
    private func applyFocusPause() {
        let applies = settings.pausesWhileMinecraftNotFocused && !isTestRun && !isPlacing && minecraftWasFront
        let focused = services.minecraft.active?.isFrontmost == true
        if applies, !focused, phase == .counting {
            if engine.pause() {
                isAutoPaused = true
                enterPause()
            }
        } else if isAutoPaused, phase == .paused, focused || !applies {
            if engine.resume() {
                isAutoPaused = false
                leavePause()
            }
        }
    }
}
