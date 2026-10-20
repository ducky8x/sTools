import CoreMedia
import Foundation

/// One tick of the output clock.
public struct FrameTick: Equatable, Sendable {
    /// 0 for the first tick. Output frame `index` is stamped `index / framesPerSecond` after the origin.
    public let index: Int64
    /// The presentation time of the output frame, relative to the recording's origin.
    public let time: CMTime
    /// The origin plus `time`: the same instant on the host clock, which audio samples are stamped with.
    public let hostTime: CMTime
    /// Output slots that went by without a tick because the clock ran late. They are not filled with copies.
    public let skippedSlots: Int
}

/// Fires `handler` repeatedly. The frame clock works out which output slot is due from the media clock,
/// so a driver only has to wake up about once per frame.
public protocol TickDriver: AnyObject, Sendable {
    func start(interval: Double, handler: @escaping @Sendable () -> Void)
    func stop()
}

/// A repeating `DispatchSourceTimer` on `queue` (a serial queue, so ticks never overlap).
public final class DispatchTickDriver: TickDriver, @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public func start(interval: Double, handler: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(interval * 1_000_000_000)), leeway: .microseconds(500))
        timer.setEventHandler(handler: handler)
        lock.lock()
        let old = self.timer
        self.timer = timer
        lock.unlock()
        old?.cancel()
        timer.resume()
    }

    public func stop() {
        lock.lock()
        let old = timer
        timer = nil
        lock.unlock()
        old?.cancel()
    }
}

/// A fixed-rate tick scheduler. Tick `n` is stamped `origin + n / fps` exactly, whatever the timer jitter:
/// stamps come from the slot, never from accumulated sleeps, so there is no drift. If the system stalls and
/// several slots go by, the next tick lands on the current slot and reports the skipped ones.
public final class FrameClock: @unchecked Sendable {
    public let framesPerSecond: Int

    private let clock: any MediaClock
    private let driver: any TickDriver
    private let onTick: @Sendable (FrameTick) -> Void
    private let lock = NSLock()
    private var origin = CMTime.zero
    private var lastIndex: Int64 = -1
    private var running = false

    /// How far past a slot boundary a wake-up may be rounded in, as a fraction of a frame.
    private static let tolerance = 0.02

    public init(
        framesPerSecond: Int, clock: any MediaClock = HostMediaClock(), driver: any TickDriver,
        onTick: @escaping @Sendable (FrameTick) -> Void
    ) {
        self.framesPerSecond = max(1, framesPerSecond)
        self.clock = clock
        self.driver = driver
        self.onTick = onTick
    }

    /// Starts ticking. `origin` is the host time of output frame 0; it defaults to now.
    public func start(origin: CMTime? = nil) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        self.origin = origin ?? clock.now()
        lastIndex = -1
        lock.unlock()
        driver.start(interval: 1.0 / Double(framesPerSecond)) { [weak self] in self?.wake() }
    }

    /// Stops ticking and returns the index of the last tick delivered, or nil if none was.
    @discardableResult
    public func stop() -> Int64? {
        lock.lock()
        let wasRunning = running
        running = false
        let last = lastIndex
        lock.unlock()
        if wasRunning { driver.stop() }
        return last >= 0 ? last : nil
    }

    private func wake() {
        let now = clock.now()
        lock.lock()
        guard running else { lock.unlock(); return }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(now, origin))
        guard elapsed.isFinite, elapsed > -1 else { lock.unlock(); return }
        let due = Int64((elapsed * Double(framesPerSecond) + Self.tolerance).rounded(.down))
        guard due > lastIndex else { lock.unlock(); return }
        let skipped = lastIndex < 0 ? Int(max(0, due)) : Int(due - lastIndex - 1)
        lastIndex = max(due, 0)
        let index = lastIndex
        let origin = self.origin
        lock.unlock()
        let time = CMTime(value: index, timescale: Int32(framesPerSecond))
        onTick(FrameTick(index: index, time: time, hostTime: CMTimeAdd(origin, time), skippedSlots: skipped))
    }
}
