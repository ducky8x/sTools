import AVFoundation
import CoreGraphics
import Foundation
import STDesign
@testable import STPlatform
import Testing
@testable import TimerOverlay

// Shared fakes for the controller's tests. Nothing here plays a sound, shows a window, posts a VoiceOver
// announcement, asks for a permission or registers a hotkey. The controller is built through its public init only,
// with public fakes, as the app's tests must be able to build it; only `isQuiet` reads an internal flag.

// MARK: - Clock and wakes

@MainActor
final class TestClock: TimerClock {
    var time: TimeInterval
    init(_ time: TimeInterval = 10_000) { self.time = time }
    func now() -> TimeInterval { time }
}

@MainActor
final class TestWake: TimerScheduledWake {
    let due: TimeInterval
    let action: @MainActor () -> Void
    var isCancelled = false
    var hasFired = false

    init(due: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.due = due
        self.action = action
    }

    func cancel() { isCancelled = true }
}

/// Wakes fire only when a test says so, moving the clock to each one's due time.
@MainActor
final class TestScheduler: TimerScheduling {
    let clock: TestClock
    private(set) var wakes: [TestWake] = []

    init(clock: TestClock) { self.clock = clock }

    var pending: [TestWake] { wakes.filter { !$0.isCancelled && !$0.hasFired } }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledWake {
        let wake = TestWake(due: clock.time + max(0, delay), action: action)
        wakes.append(wake)
        return wake
    }

    /// Fires the earliest pending wake, moving the clock to its time. False when nothing is pending.
    @discardableResult
    func fireNext() -> Bool {
        guard let next = pending.min(by: { $0.due < $1.due }) else { return false }
        clock.time = max(clock.time, next.due)
        next.hasFired = true
        next.action()
        return true
    }

    /// Fires every wake due within `seconds` from now, in order, then leaves the clock there.
    func advance(by seconds: TimeInterval) {
        let target = clock.time + seconds
        while let next = pending.min(by: { $0.due < $1.due }), next.due <= target + 1e-9 { fireNext() }
        clock.time = max(clock.time, target)
    }

    /// Fires wakes until none is pending, or `limit` have fired.
    @discardableResult
    func fireAll(limit: Int = 100_000) -> Int {
        var count = 0
        while count < limit, fireNext() { count += 1 }
        return count
    }
}

@MainActor
final class TestActivity: TimerActivity {
    private(set) var isHeld = false
    private(set) var begins = 0

    func begin() {
        isHeld = true
        begins += 1
    }

    func end() { isHeld = false }
}

@MainActor
final class TestWakeWatcher: TimerWakeWatching {
    private var handler: (@MainActor () -> Void)?
    var isWatching: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    func stop() { handler = nil }

    /// What `NSWorkspace.didWakeNotification` would do.
    func macWoke() { handler?() }
}

// MARK: - The overlay

/// Records what the controller asks of the overlay, and the motion the live presenter would play for it, using the
/// same pure `TimerMotion`.
@MainActor
final class TestPresenter: TimerOverlayPresenting {
    struct PopIn {
        let content: TimerOverlayContent
        let settings: TimerOverlaySettings
        let plateFrame: CGRect
        let displayFrame: CGRect
        let reduceMotion: Bool
    }

    /// The plate's size for any content.
    var size = CGSize(width: 124, height: 66)
    /// Pop-outs finish at once, as the live one does while motion is reduced. Off, `finishExit()` finishes them.
    var exitsAtOnce = true

    private(set) var popIns: [PopIn] = []
    private(set) var popOuts: [Bool] = []
    private(set) var updates: [TimerOverlayContent] = []
    private(set) var settingsUpdates = 0
    private(set) var moves: [(plateFrame: CGRect, displayFrame: CGRect)] = []
    private(set) var pulses: [Bool] = []
    /// Every step of motion the live presenter would play.
    private(set) var motion: [TimerMotion.Step] = []
    private(set) var isPlacing = false
    private(set) var isShowing = false
    private(set) var plateFrame: CGRect?
    private var settings = TimerOverlaySettings()
    private var displayFrame = CGRect.zero
    private var exitCompletions: [@MainActor () -> Void] = []
    private var onDragChanged: (@MainActor (CGSize) -> Void)?
    private var onDragEnded: (@MainActor () -> Void)?

    /// The steps that move anything: a scale, a slide, a fade, a pulse or a flash.
    var movingSteps: [TimerMotion.Step] { motion.filter { !$0.isStill || $0.animation != nil } }

    func plateSize(for content: TimerOverlayContent, settings: TimerOverlaySettings) -> CGSize { size }

    func popIn(_ content: TimerOverlayContent, settings: TimerOverlaySettings, plateFrame: CGRect,
               displayFrame: CGRect, reduceMotion: Bool) {
        // A pop-in during an exit releases the old panel; that exit's completion never runs.
        exitCompletions.removeAll()
        popIns.append(PopIn(content: content, settings: settings, plateFrame: plateFrame, displayFrame: displayFrame,
                            reduceMotion: reduceMotion))
        self.settings = settings
        self.plateFrame = plateFrame
        self.displayFrame = displayFrame
        isShowing = true
        motion.append(TimerMotion.popIn(settings.popUpMotion, from: TimerMotion.nearestEdge(of: plateFrame, in: displayFrame),
                                        reduceMotion: reduceMotion))
    }

    func update(_ content: TimerOverlayContent) {
        guard isShowing else { return }
        updates.append(content)
    }

    func update(settings: TimerOverlaySettings) {
        guard isShowing else { return }
        self.settings = settings
        settingsUpdates += 1
    }

    func move(plateFrame: CGRect, displayFrame: CGRect) {
        guard isShowing else { return }
        moves.append((plateFrame, displayFrame))
        self.plateFrame = plateFrame
        self.displayFrame = displayFrame
    }

    func pulse(reduceMotion: Bool) {
        guard isShowing else { return }
        pulses.append(reduceMotion)
        motion += TimerMotion.ring(settings.whileRinging, reduceMotion: reduceMotion)
    }

    func popOut(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        guard isShowing else {
            completion()
            return
        }
        popOuts.append(reduceMotion)
        if let plateFrame {
            motion.append(TimerMotion.popOut(settings.popUpMotion,
                                             toward: TimerMotion.nearestEdge(of: plateFrame, in: displayFrame),
                                             reduceMotion: reduceMotion))
        }
        exitCompletions.append(completion)
        if exitsAtOnce || reduceMotion { finishExit() }
    }

    /// The exit's animation ends and its panel is released.
    func finishExit() {
        guard !exitCompletions.isEmpty else { return }
        isShowing = false
        plateFrame = nil
        let completions = exitCompletions
        exitCompletions.removeAll()
        for completion in completions { completion() }
    }

    var isLeaving: Bool { !exitCompletions.isEmpty }

    func setPlacementMode(_ isOn: Bool, onDragChanged: @escaping @MainActor (CGSize) -> Void,
                          onDragEnded: @escaping @MainActor () -> Void) {
        isPlacing = isOn
        self.onDragChanged = isOn ? onDragChanged : nil
        self.onDragEnded = isOn ? onDragEnded : nil
    }

    /// The mouse drags the plate by `translation` from where the drag started (+x right, +y down).
    func drag(by translation: CGSize) { onDragChanged?(translation) }
    func endDrag() { onDragEnded?() }
}

@MainActor
final class TestGuides: RuleGuidesPresenting {
    private(set) var shown: [(zones: RuleZones, display: DisplayInfo)] = []
    private(set) var marks: [[RuleZones.Kind]] = []
    private(set) var hides = 0
    private(set) var isShowing = false

    func show(_ zones: RuleZones, on display: DisplayInfo) {
        shown.append((zones, display))
        isShowing = true
    }

    func markCovered(_ kinds: [RuleZones.Kind], plateFrame: CGRect) { marks.append(kinds) }

    func hide() {
        hides += 1
        isShowing = false
    }
}

// MARK: - Sound and speech

/// Rings on the test scheduler at the schedule's times, as the live player reports them, and plays nothing.
@MainActor
final class TestAlarm: AlarmPlaying {
    struct Ring {
        let sound: URL
        let volume: Double
        let schedule: AlarmSchedule
    }

    private(set) var rings: [Ring] = []
    private(set) var ringStarts: [Int] = []
    private(set) var cues: [AlarmSchedule.Cue] = []
    private(set) var previews: [(sound: URL, rings: Int)] = []
    private(set) var stops = 0
    private(set) var isPlaying = false
    var onRenderedBuffer: (@Sendable (AlarmRenderedBuffer) -> Void)?
    private let scheduler: TestScheduler
    private var wakes: [any TimerScheduledWake] = []

    init(scheduler: TestScheduler) { self.scheduler = scheduler }

    func ring(_ sound: URL, volume: Double, schedule: AlarmSchedule,
              onRing: @escaping @MainActor (_ index: Int) -> Void, onEnd: @escaping @MainActor () -> Void) {
        replace()
        rings.append(Ring(sound: sound, volume: volume, schedule: schedule))
        isPlaying = true
        for (index, start) in schedule.ringStarts.enumerated() {
            wakes.append(scheduler.schedule(after: start) { [weak self] in
                self?.ringStarts.append(index)
                onRing(index)
            })
        }
        wakes.append(scheduler.schedule(after: schedule.alarmEnd) { [weak self] in
            self?.isPlaying = false
            onEnd()
        })
    }

    func playCue(_ cue: AlarmSchedule.Cue, volume: Double) {
        replace()
        cues.append(cue)
        isPlaying = true
        wakes.append(scheduler.schedule(after: 0.2) { [weak self] in self?.isPlaying = false })
    }

    func preview(_ sound: URL, volume: Double, rings: Int, onEnd: @escaping @MainActor () -> Void) {
        replace()
        previews.append((sound, rings))
        isPlaying = true
        wakes.append(scheduler.schedule(after: Double(rings) * 1.85) { [weak self] in
            self?.isPlaying = false
            onEnd()
        })
    }

    func stop() {
        stops += 1
        replace()
    }

    /// One thing plays at a time: what played before stops, and its callbacks never run.
    private func replace() {
        for wake in wakes { wake.cancel() }
        wakes.removeAll()
        isPlaying = false
    }
}

@MainActor
final class TestAnnouncer: TimerAnnouncing {
    private(set) var announcements: [TimerAnnouncement] = []
    func announce(_ announcement: TimerAnnouncement) { announcements.append(announcement) }
}

// MARK: - Services

/// Displays far outside every real one, so nothing a test places could reach a screen.
let timerTestDisplay = DisplayInfo(
    id: 1, name: "Off screen", frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -9000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: true)
let timerSecondTestDisplay = DisplayInfo(
    id: 2, name: "Off screen too", frame: CGRect(x: -6000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -6000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: false)

struct TimerTestProber: PermissionProbing {
    var accessibility: PermissionStatus = .granted
    func status(for permission: Permission) -> PermissionStatus { permission == .accessibility ? accessibility : .granted }
    func request(_ permission: Permission) async -> PermissionStatus { status(for: permission) }
}

/// A Minecraft window on `display`, in front or not.
func minecraftInstance(on display: DisplayInfo, isFrontmost: Bool) -> MinecraftInstance {
    MinecraftInstance(
        window: MinecraftWindow(windowNumber: 7, processID: 4242, title: "Minecraft* 1.16.1", frame: display.bounds),
        launchDate: Date(timeIntervalSince1970: 1_000), isFrontmost: isFrontmost, displayID: display.id)
}

/// A controller with every seam faked, in its own settings folder.
@MainActor
final class TimerRig {
    let directory: URL
    let clock = TestClock()
    let scheduler: TestScheduler
    let activity = TestActivity()
    let wakeWatcher = TestWakeWatcher()
    let presenter = TestPresenter()
    let guides = TestGuides()
    let alarm: TestAlarm
    let announcer = TestAnnouncer()
    let minecraftSource = StaticMinecraftWindowSource()
    let services: ToolServices
    let theme: STTheme
    let controller: TimerOverlayController

    init(reduceMotion: Bool = false, accessibility: PermissionStatus = .granted,
         displays: [DisplayInfo] = [timerTestDisplay, timerSecondTestDisplay],
         settings edit: (inout TimerOverlaySettings) -> Void = { _ in }) {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "sTools-timer-controller-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scheduler = TestScheduler(clock: clock)
        alarm = TestAlarm(scheduler: scheduler)
        let store = SettingsStore(directory: directory)
        var settings = TimerOverlaySettings()
        edit(&settings)
        store.save(settings)
        services = ToolServices(
            settings: store, displays: DisplayDirectory(screenProvider: { displays }),
            minecraft: MinecraftLocator(source: minecraftSource),
            permissions: PermissionCenter(prober: TimerTestProber(accessibility: accessibility),
                                          openURL: { _ in }, systemNotifications: NotificationCenter()))
        theme = STTheme(motionMode: reduceMotion ? .reduced : .full)
        controller = TimerOverlayController(
            services: services, theme: theme, clock: clock, scheduler: scheduler, activity: activity,
            wakeWatcher: wakeWatcher, presenter: presenter, guides: guides, alarm: alarm, announcer: announcer)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Minecraft as it is now: running on `display`, in front or not, or not running.
    func setMinecraft(on display: DisplayInfo?, isFrontmost: Bool = true) async {
        minecraftSource.instances = display.map { [minecraftInstance(on: $0, isFrontmost: isFrontmost)] } ?? []
        services.minecraft.refresh()
        await settle()
    }

    /// Lets the controller's observation tasks run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Runs the clock until the countdown reaches zero.
    func runToZero() {
        while controller.phase == .counting || controller.phase == .paused {
            guard scheduler.fireNext() else { return }
        }
    }

    /// Nothing runs: no panel, no wake, no activity, no sound, no observer of Minecraft, the displays or wake.
    var isQuiet: Bool {
        !presenter.isShowing && scheduler.pending.isEmpty && !activity.isHeld && !alarm.isPlaying
            && !wakeWatcher.isWatching && !controller.isWatchingEnvironment
    }

    /// A sound file `seconds` long in the settings folder's `Sounds/`, as the owner's own; its settings ID.
    func ownSound(named name: String = "Tone.caf", seconds: Double) throws -> String {
        let folder = directory.appending(path: SettingsLayout.soundsFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeSilence(seconds: seconds, to: folder.appending(path: name))
        return "file:\(name)"
    }
}

/// Writes `seconds` of silence as a sound file. Writing plays nothing.
func writeSilence(seconds: Double, to url: URL) throws {
    let rate = 48_000.0
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount((seconds * rate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    if let channel = buffer.floatChannelData?[0] { channel.update(repeating: 0, count: Int(frames)) }
    try file.write(from: buffer)
}
