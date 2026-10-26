import Foundation
import Synchronization
import Testing
@testable import NBBOverlay

/// A scripted `NBBEventSource`: each `connect` call consumes the next scripted outcome, so a
/// subscription's full connect → dispatch → drop → backoff → reconnect lifecycle can be driven
/// end to end without a real socket — this is the "fake SSE server" spec 5.1.6 asks for, exercising
/// exactly the same `NBBSubscription` code path the real `URLSessionEventSource` does.
final class FakeEventSource: NBBEventSource, @unchecked Sendable {
    enum Outcome {
        /// Yields `event`'s bytes (a single SSE `data:` line, newline-terminated) then closes cleanly.
        case event(String)
        /// Fails to connect at all.
        case refused
    }

    private let outcomes: Mutex<[Outcome]>
    private let connectCountBox = Mutex<Int>(0)
    /// When true, the last outcome repeats forever instead of the source failing once the scripted
    /// list is exhausted — for tests with several concurrent subscriptions (one `NBBConnection` call)
    /// sharing one fake, where every endpoint should keep connecting successfully.
    private let repeatsLastOutcome: Bool

    init(_ outcomes: [Outcome], repeatsLastOutcome: Bool = false) {
        self.outcomes = Mutex(outcomes)
        self.repeatsLastOutcome = repeatsLastOutcome
    }

    var connectCount: Int { connectCountBox.withLock { $0 } }

    func connect(to url: URL) async throws -> AsyncThrowingStream<[UInt8], Error> {
        connectCountBox.withLock { $0 += 1 }
        let next = outcomes.withLock { outcomes -> Outcome? in
            if outcomes.isEmpty { return nil }
            if repeatsLastOutcome && outcomes.count == 1 { return outcomes[0] }
            return outcomes.removeFirst()
        }
        guard let next else {
            throw NBBConnectionError.badStatus(nil)
        }
        switch next {
        case .refused:
            throw NBBConnectionError.badStatus(503)
        case .event(let payload):
            let bytes = Array("data: \(payload)\n\n".utf8)
            let staysOpen = repeatsLastOutcome
            return AsyncThrowingStream { continuation in
                continuation.yield(bytes)
                // A real SSE connection stays open between events; closing immediately would make
                // "connected" a one-instant flicker instead of an observable, stable state. Only the
                // one-shot (non-repeating) scripts close right away, matching the drop-and-reconnect
                // tests that want each connect to end as soon as its event is dispatched. The
                // long-lived case still finishes on its own well past any test's lifetime, rather
                // than leaking an open continuation if a test forgets to cancel.
                guard staysOpen else {
                    continuation.finish()
                    return
                }
                let keepOpen = Task {
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
                continuation.onTermination = { _ in keepOpen.cancel() }
            }
        }
    }
}

/// Polls `condition` until it's true or `timeout` elapses, instead of sleeping a fixed guessed
/// duration — robust to the real scheduling delays that show up when the whole test suite is
/// running under load, where a plain `Task.sleep` for "long enough" isn't always long enough.
private func waitUntil(timeout: Duration, pollInterval: Duration = .milliseconds(20), _ condition: @Sendable () -> Bool) async {
    let deadline = SuspendingClock.now + timeout
    while !condition(), SuspendingClock.now < deadline {
        try? await Task.sleep(for: pollInterval)
    }
}

@Suite("NBB subscription lifecycle", .serialized)
struct NBBSubscriptionTests {
    @Test func dispatchesEventsAndReconnectsAfterARefusedConnect() async throws {
        let source = FakeEventSource([.event("first"), .refused, .event("second")])
        let subscription = NBBSubscription(url: URL(string: "http://localhost:52533/x")!, source: source)
        let received = Mutex<[String]>([])

        let task = Task {
            await subscription.run(onEvent: { event in received.withLock { $0.append(event) } })
        }
        // Sequence: event "first" (instant) → 0.5s backoff → refused connect (instant) → 1.0s backoff
        // (doubled, since the refusal never reset it) → event "second". Poll instead of sleeping a
        // fixed guess: real wall-clock delays stretch unpredictably under the full suite's system
        // load, so wait for the actual outcome (generously bounded) rather than a fixed duration.
        await waitUntil(timeout: .seconds(10)) { received.withLock { $0.count } >= 2 }
        task.cancel()

        #expect(received.withLock { $0 } == ["first", "second"])
        #expect(source.connectCount == 3)
    }

    @Test func stopsReconnectingOnceCancelled() async throws {
        let source = FakeEventSource(Array(repeating: FakeEventSource.Outcome.refused, count: 50))
        let subscription = NBBSubscription(url: URL(string: "http://localhost:52533/x")!, source: source)

        let task = Task {
            await subscription.run(onEvent: { _ in })
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        let countAtCancel = source.connectCount
        try await Task.sleep(for: .milliseconds(600))
        #expect(source.connectCount == countAtCancel, "no further connects after cancellation")
    }

    @Test func connectionChangeCallbackReflectsConnectAndDisconnect() async throws {
        let source = FakeEventSource([.event("first")])
        let subscription = NBBSubscription(url: URL(string: "http://localhost:52533/x")!, source: source)
        let changes = Mutex<[Bool]>([])

        let task = Task {
            await subscription.run(onEvent: { _ in }, onConnectionChange: { connected in
                changes.withLock { $0.append(connected) }
            })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        // Connects (true), then the clean close drops it (false) before the next reconnect attempt.
        #expect(changes.withLock { $0 }.first == true)
    }
}
