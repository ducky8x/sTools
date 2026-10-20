import Observation

/// Tracks the animations playing on the current step, so any click or key can complete them (spec 4.1).
/// Views announce how long they will animate with `run(for:)` and jump to their end state whenever
/// `completionCount` changes.
@MainActor
@Observable
public final class PrologueAnimations {
    /// Bumped by `completeAll()`; every running animation watches it.
    public private(set) var completionCount = 0

    @ObservationIgnored private var runningUntil: ContinuousClock.Instant?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant

    public init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    public var isRunning: Bool {
        guard let runningUntil else { return false }
        return now() < runningUntil
    }

    /// Marks an animation that will play for `duration` from now.
    public func run(for duration: Duration) {
        let end = now() + duration
        if let runningUntil, runningUntil > end { return }
        runningUntil = end
    }

    /// Completes everything that is playing. Returns whether anything was.
    @discardableResult
    public func completeAll() -> Bool {
        guard isRunning else { return false }
        runningUntil = nil
        completionCount += 1
        return true
    }

    /// A new page starts with nothing playing.
    func reset() {
        runningUntil = nil
    }
}
