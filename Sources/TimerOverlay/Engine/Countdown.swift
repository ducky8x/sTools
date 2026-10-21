import Foundation

/// The countdown's pure state machine, ported from the merged timer app's core (spec 5.6.10).
///
/// Time is passed in as seconds on a monotonic clock, so tests and the running app exercise the same code.
/// `TimerEngine` supplies the clock and wakes it once per shown change.
public struct Countdown: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, running, paused, finished
    }

    /// Times within this of a change of the shown value count as on it, so float noise in `deadline - now`
    /// can never show one second more at the start, or wake twice for one change.
    static let slack: TimeInterval = 1e-6
    /// How far past a change each wake lands: just after it, never just before.
    static let wakePad: TimeInterval = 0.002
    /// The last seconds that show tenths when tenths are on.
    public static let tenthsWindow: TimeInterval = 10

    public private(set) var phase: Phase = .idle
    /// This run's length: the duration it started with, or the length passed to `start`. 0 before the first run.
    public private(set) var length: TimeInterval = 0

    private var storedDuration: TimeInterval
    private var deadline: TimeInterval = 0
    private var frozen: TimeInterval = 0

    public init(duration: TimeInterval) {
        storedDuration = Self.sanitized(duration)
    }

    /// The length used by the next run. Changing it never disturbs a run in progress.
    public var duration: TimeInterval {
        get { storedDuration }
        set { storedDuration = Self.sanitized(newValue) }
    }

    public var canStart: Bool { duration > 0 }

    /// Starts a fresh run, from any phase: starting while running, paused or finished restarts.
    ///
    /// The run lasts `duration`, or `length` when given: the page's 5-second Test runs that way and leaves the
    /// saved duration alone. Returns false only when the run's length is zero.
    @discardableResult
    public mutating func start(at now: TimeInterval, length: TimeInterval? = nil) -> Bool {
        let runLength = length.map(Self.sanitized) ?? duration
        guard runLength > 0 else { return false }
        self.length = runLength
        deadline = now + runLength
        phase = .running
        return true
    }

    @discardableResult
    public mutating func pause(at now: TimeInterval) -> Bool {
        guard phase == .running, now < deadline else { return false }   // an expired run must finish, not freeze at 0
        frozen = max(0, deadline - now)
        phase = .paused
        return true
    }

    @discardableResult
    public mutating func resume(at now: TimeInterval) -> Bool {
        guard phase == .paused else { return false }
        deadline = now + frozen
        phase = .running
        return true
    }

    /// Ends the run from any phase, back to idle.
    public mutating func cancel() {
        phase = .idle
    }

    /// Advances to `finished` once the deadline has passed, however long ago (the Mac may have slept past it).
    /// True only on the transition.
    @discardableResult
    public mutating func update(at now: TimeInterval) -> Bool {
        guard phase == .running, now >= deadline else { return false }
        phase = .finished
        return true
    }

    /// The time left: the duration while idle, the frozen time while paused, 0 once finished.
    public func remaining(at now: TimeInterval) -> TimeInterval {
        switch phase {
        case .idle: duration
        case .running: max(0, deadline - now)
        case .paused: frozen
        case .finished: 0
        }
    }

    /// Whole seconds shown on screen; rounds up so 00:00 appears only when time is up.
    public func displaySeconds(at now: TimeInterval) -> Int {
        Self.unitsShown(remaining(at: now), perSecond: 1)
    }

    /// The fraction of the current run still left, 1 → 0.
    public func progress(at now: TimeInterval) -> Double {
        switch phase {
        case .idle: return 1
        case .finished: return 0
        case .running, .paused:
            guard length > 0 else { return 0 }
            return min(1, remaining(at: now) / length)
        }
    }

    /// `progress` stepped with the shown seconds, for the overlay's bar and ring, which step once a second.
    public func steppedProgress(at now: TimeInterval) -> Double {
        switch phase {
        case .idle: return 1
        case .finished: return 0
        case .running, .paused:
            guard length > 0 else { return 0 }
            return min(1, Double(displaySeconds(at: now)) / length)
        }
    }

    /// How long ago the run reached zero, for the overtime display. 0 unless finished.
    public func timeSinceZero(at now: TimeInterval) -> TimeInterval {
        phase == .finished ? max(0, now - deadline) : 0
    }

    /// Seconds until the shown value next changes, or nil when it won't change by itself.
    ///
    /// While running, the shown value steps once a second, or every tenth in the last 10 s with `tenths`.
    /// After zero it changes only while `overtime` shows, once a second as it counts up. Idle and paused
    /// never change. Each delay lands 2 ms past the change; a run already past its deadline asks for 0.
    public func delayToNextDisplayChange(at now: TimeInterval, tenths: Bool = false, overtime: Bool = false) -> TimeInterval? {
        switch phase {
        case .idle, .paused:
            return nil
        case .running:
            let left = deadline - now
            guard left > 0 else { return 0 }
            let perSecond: Double = Self.showsTenths(left, tenths: tenths) ? 10 : 1
            let shown = Self.unitsShown(left, perSecond: perSecond)
            // Zero itself is the next change when the shown value already reads zero.
            guard shown > 0 else { return left + Self.wakePad }
            return left - Double(shown - 1) / perSecond + Self.wakePad
        case .finished:
            guard overtime else { return nil }
            let since = max(0, now - deadline)
            return (since + Self.slack).rounded(.down) + 1 - since + Self.wakePad
        }
    }

    // MARK: - Shared with ClockFormat

    /// Whether `remaining` falls in the tenths window.
    static func showsTenths(_ remaining: TimeInterval, tenths: Bool) -> Bool {
        tenths && remaining <= tenthsWindow + slack
    }

    /// The shown count of `1 / perSecond` units left, rounded up.
    static func unitsShown(_ remaining: TimeInterval, perSecond: Double) -> Int {
        let units = ((remaining - slack) * perSecond).rounded(.up)
        return units > 0 ? Int(min(units, 1e15)) : 0
    }

    private static func sanitized(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
