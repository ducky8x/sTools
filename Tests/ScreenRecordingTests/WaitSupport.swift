import Foundation

/// Waits for `condition`, checking it again every few milliseconds and yielding in between, for at most `timeout` of
/// awake time. The bound is a deadline on `SuspendingClock`, not a count of pauses, so a busy Mac that stretches every
/// pause can't use it up early, and a Mac that sleeps in the middle of a run can't use it up at all. Returns whether
/// the condition held; a test that needs it wraps the call in `#expect`.
///
/// The condition runs on the caller's actor, so a main-actor test can read main-actor state in it.
func waitUntil(
    timeout: Duration = .seconds(20), isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
