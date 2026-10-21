import AppKit
import Foundation
import Observation

/// Keeps App Nap from delaying the timer while a run is live: its wakes, the alarm, the pulses and the exit.
@MainActor
public protocol TimerActivity {
    /// Starts holding the activity. The engine calls it once per hold, and `end()` before the next.
    func begin()
    /// Stops holding it.
    func end()
}

/// The live activity: `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)`, which keeps
/// App Nap away without keeping the Mac awake.
@MainActor
public final class ProcessTimerActivity: TimerActivity {
    private var token: NSObjectProtocol?

    public init() {}

    public var isHeld: Bool { token != nil }

    public func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Timer Overlay is counting down")
    }

    public func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

/// Tells the engine when the Mac wakes from sleep, so it re-reads the clock at once.
@MainActor
public protocol TimerWakeWatching {
    /// Starts calling `handler` each time the Mac wakes, until `stop()`.
    func start(_ handler: @escaping @MainActor () -> Void)
    func stop()
}

/// The live watcher: `NSWorkspace.didWakeNotification`, observed only between `start` and `stop`.
@MainActor
public final class WorkspaceWakeWatcher: TimerWakeWatching {
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    public var isWatching: Bool { observer != nil }

    public func start(_ handler: @escaping @MainActor () -> Void) {
        stop()
        observer = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    public func stop() {
        guard let observer else { return }
        center.removeObserver(observer)
        self.observer = nil
    }
}

/// Runs a `Countdown` in real time (spec 5.6.10) and costs nothing while nothing counts (spec 9.3).
///
/// - It reads a monotonic clock that counts through sleep, and re-reads it when the Mac wakes, so a run that
///   passed zero during sleep finishes, and rings, on wake.
/// - It keeps at most one wake scheduled, for the next change of the shown time: once a second, every tenth
///   in the last 10 s with tenths on, and once a second after zero while overtime shows. Idle, paused, or
///   after zero without overtime, nothing is scheduled.
/// - It holds a process activity from a run's start until it's cancelled, except while paused, so App Nap
///   delays neither the alarm nor the exit after it. The controller cancels the run once the overlay has left.
/// - It watches for the Mac waking only while counting.
///
/// The countdown it exposes changes only with its run (start, pause, resume, zero, cancel), never on a plain
/// tick, so observing it costs nothing while counting. Each tick reaches `onTick` instead.
@MainActor
@Observable
public final class TimerEngine {
    /// The countdown as of the last action or wake.
    public private(set) var countdown: Countdown

    /// Tenths in the last 10 s: the engine wakes every tenth there. A change applies at once.
    @ObservationIgnored public var showsTenths = false {
        didSet { if showsTenths != oldValue { settle(at: clock.now()) } }
    }

    /// Overtime after zero: the engine keeps waking once a second until the run is cancelled. A change applies
    /// at once.
    @ObservationIgnored public var showsOvertime = false {
        didSet { if showsOvertime != oldValue { settle(at: clock.now()) } }
    }

    /// Called with the wake's time at each wake while the countdown runs (each shown change, or a re-read after
    /// the Mac woke) and at each overtime wake after zero.
    @ObservationIgnored public var onTick: (@MainActor (_ now: TimeInterval) -> Void)?

    /// Called once per run when it reaches zero, with the time that was noticed: zero itself, or the wake when
    /// the Mac slept past it. That wake doesn't also reach `onTick`.
    @ObservationIgnored public var onFinish: (@MainActor (_ now: TimeInterval) -> Void)?

    /// Whether the engine holds the process activity.
    @ObservationIgnored public private(set) var isHoldingActivity = false
    /// Whether the engine watches for the Mac waking.
    @ObservationIgnored public private(set) var isWatchingForWake = false

    private let clock: any TimerClock
    private let scheduler: any TimerScheduling
    private let activity: any TimerActivity
    private let wakeWatcher: any TimerWakeWatching
    @ObservationIgnored private var pendingWake: (any TimerScheduledWake)?

    public init(
        duration: TimeInterval,
        clock: any TimerClock = MonotonicClock(),
        scheduler: any TimerScheduling = DispatchTimerScheduler(),
        activity: any TimerActivity = ProcessTimerActivity(),
        wakeWatcher: any TimerWakeWatching = WorkspaceWakeWatcher()
    ) {
        countdown = Countdown(duration: duration)
        self.clock = clock
        self.scheduler = scheduler
        self.activity = activity
        self.wakeWatcher = wakeWatcher
    }

    public var phase: Countdown.Phase { countdown.phase }

    /// The next run's length. A change never disturbs a run in progress.
    public var duration: TimeInterval {
        get { countdown.duration }
        set {
            var next = countdown
            next.duration = newValue
            if next != countdown { countdown = next }
        }
    }

    /// Whether a wake is scheduled.
    public var hasPendingWake: Bool { pendingWake != nil }

    /// The engine's clock, now.
    public func now() -> TimeInterval { clock.now() }

    /// Starts a fresh run, restarting one in any phase. `length` runs once for another length and leaves
    /// `duration` alone. False only when the run's length is zero.
    @discardableResult
    public func start(length: TimeInterval? = nil) -> Bool {
        let now = clock.now()
        var next = countdown
        guard next.start(at: now, length: length) else { return false }
        countdown = next
        settle(at: now)
        return true
    }

    /// Pauses a running countdown. Refused once zero has passed: that run finishes at its next wake instead.
    @discardableResult
    public func pause() -> Bool {
        let now = clock.now()
        var next = countdown
        guard next.pause(at: now) else { return false }
        countdown = next
        settle(at: now)
        return true
    }

    @discardableResult
    public func resume() -> Bool {
        let now = clock.now()
        var next = countdown
        guard next.resume(at: now) else { return false }
        countdown = next
        settle(at: now)
        return true
    }

    /// Ends the run from any phase. Nothing stays scheduled, held or watched.
    public func cancel() {
        var next = countdown
        next.cancel()
        if next != countdown { countdown = next }
        settle(at: clock.now())
    }

    /// Re-reads the clock now, as after the Mac wakes: finishes a run that passed zero, and reschedules the next
    /// wake from the new time.
    public func refresh() {
        advance(to: clock.now())
    }

    private func wake() {
        pendingWake = nil
        advance(to: clock.now())
    }

    private func advance(to now: TimeInterval) {
        var next = countdown
        let finished = next.update(at: now)
        if next != countdown { countdown = next }
        settle(at: now)
        if finished {
            onFinish?(now)
        } else if countdown.phase == .running || (countdown.phase == .finished && showsOvertime) {
            onTick?(now)
        }
    }

    /// Brings the activity, the wake watcher and the one scheduled wake in line with the countdown at `now`.
    private func settle(at now: TimeInterval) {
        let phase = countdown.phase

        let wantsActivity = phase == .running || phase == .finished
        if wantsActivity != isHoldingActivity {
            if wantsActivity { activity.begin() } else { activity.end() }
            isHoldingActivity = wantsActivity
        }

        let wantsWakeWatch = phase == .running
        if wantsWakeWatch != isWatchingForWake {
            if wantsWakeWatch {
                wakeWatcher.start { [weak self] in self?.refresh() }
            } else {
                wakeWatcher.stop()
            }
            isWatchingForWake = wantsWakeWatch
        }

        pendingWake?.cancel()
        pendingWake = nil
        if let delay = countdown.delayToNextDisplayChange(at: now, tenths: showsTenths, overtime: showsOvertime) {
            pendingWake = scheduler.schedule(after: delay) { [weak self] in self?.wake() }
        }
    }
}
