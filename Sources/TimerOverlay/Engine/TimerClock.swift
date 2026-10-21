import Foundation

/// Seconds on a clock that only moves forward and keeps counting while the Mac sleeps (spec 5.6.1, "Real
/// time"). The engine and the controller read the same one, so the countdown, the 0.4 s double press and the
/// 1 s hold are measured on one clock. Tests use a fake.
@MainActor
public protocol TimerClock {
    func now() -> TimeInterval
}

/// The live clock: `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, which on macOS keeps counting through sleep.
public struct MonotonicClock: TimerClock {
    public init() {}

    public func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// A wake that hasn't fired yet.
@MainActor
public protocol TimerScheduledWake: AnyObject {
    /// Makes sure the wake's action never runs. Safe to call more than once, and after it has fired.
    func cancel()
}

/// Runs an action once, later, on the main actor: the timer's only way to wait. Nothing repeats by itself;
/// each wake is scheduled for one shown change, so an idle timer has nothing scheduled at all.
@MainActor
public protocol TimerScheduling {
    /// Runs `action` once after `delay` seconds, unless the returned wake is cancelled first.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledWake
}

/// The live scheduler: a one-shot dispatch timer on the main queue, allowed 15 ms of leeway.
///
/// It runs on uptime, which stops while the Mac sleeps, so a wake due during sleep fires late. The engine
/// re-reads the clock when the Mac wakes instead of relying on it.
public struct DispatchTimerScheduler: TimerScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledWake {
        DispatchScheduledWake(after: delay, action: action)
    }
}

@MainActor
private final class DispatchScheduledWake: TimerScheduledWake {
    private var timer: DispatchSourceTimer?

    init(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, delay), leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // A cancelled wake's handler can already be on its way; it must do nothing.
                guard let self, self.timer != nil else { return }
                self.cancel()
                action()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
