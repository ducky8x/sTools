import Foundation
import os

/// A clock the test moves by hand. `sleep` waits until `advance(by:)` carries the time to its deadline and not before,
/// so what a test checks never depends on how long a real wait took. It starts at zero.
final class ManualClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration

        /// The time since the clock started.
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }

    private enum Arrival {
        case waiting, due, cancelled
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// When each task still asleep on this clock wakes, as the time since the clock started, earliest first.
    var pendingWakes: [Duration] { state.withLock { $0.sleepers.values.map(\.deadline.offset).sorted() } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Looking at the cancellation and parking happen under one lock, so a cancel that lands first is seen
                // here and one that lands later finds the sleeper.
                let arrival = state.withLock { state -> Arrival in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= state.now { return .due }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .waiting
                }
                switch arrival {
                case .waiting: break
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the time on in one step and wakes every sleeper whose deadline has come, earliest first. A task that wakes
    /// and sleeps again counts from the new time, so a test steps to each wake in turn to get the deadlines it expects.
    func advance(by duration: Duration) {
        let woken = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }.sorted { $0.value.deadline < $1.value.deadline }
            for (id, _) in due { state.sleepers[id] = nil }
            return due.map(\.value)
        }
        for sleeper in woken { sleeper.continuation.resume() }
    }

    /// Waits until exactly these wakes are pending, which says the task under test has reached its sleep. The wait yields
    /// to the main actor and counts only awake time, as `waitUntil` does; the minute matches the HUD suite's waits, which
    /// can sit behind page-render tests holding the main actor.
    @MainActor
    func waitForWakes(_ times: Duration..., timeout: Duration = .seconds(60)) async -> Bool {
        await waitUntil(timeout: timeout) { pendingWakes == times }
    }
}
