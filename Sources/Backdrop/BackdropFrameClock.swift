import Dispatch
import Foundation

/// A one-shot timer; cancelling it before it fires means it never does.
@MainActor
protocol BackdropFrameTimer: AnyObject {
    func cancel()
}

/// The time and one-shot timers an animated fill plays on: a GIF's next frame, a replaced fill's clean-up. Tests pass a
/// fake clock they move by hand.
@MainActor
protocol BackdropFrameClock: AnyObject {
    /// Seconds on a steady clock.
    var now: TimeInterval { get }
    /// Runs `action` once, `delay` seconds from now, unless the returned timer is cancelled first.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any BackdropFrameTimer
}

/// One-shot dispatch timers on the main queue. Nothing runs between two of them: a GIF's next frame is one timer, set
/// when the frame before it goes up.
@MainActor
final class DispatchFrameClock: BackdropFrameClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any BackdropFrameTimer {
        let source = DispatchSource.makeTimerSource(queue: .main)
        // A couple of milliseconds' leeway lets the system fold this wake-up into another.
        source.schedule(deadline: .now() + max(delay, 0), leeway: .milliseconds(2))
        // One-shot: the source cancels itself once it has fired, which also lets it go.
        source.setEventHandler {
            MainActor.assumeIsolated { action() }
            source.cancel()
        }
        source.resume()
        return DispatchFrameTimer(source: source)
    }
}

@MainActor
private final class DispatchFrameTimer: BackdropFrameTimer {
    private let source: any DispatchSourceTimer
    init(source: any DispatchSourceTimer) { self.source = source }
    func cancel() { source.cancel() }
}
