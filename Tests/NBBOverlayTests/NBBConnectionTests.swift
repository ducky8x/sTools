import Foundation
import Synchronization
import Testing
@testable import NBBOverlay

/// Records every URL asked for. Refuses while `isUp` is false (Ninjabrain Bot not running); otherwise sends each
/// endpoint's state once and keeps the stream open, like Ninjabrain Bot, until told to drop everything.
private final class RecordingSource: NBBEventSource, @unchecked Sendable {
    private let state = Mutex<(urls: [String], isUp: Bool, generation: Int)>(([], false, 0))

    func setUp(_ up: Bool) {
        state.withLock {
            $0.isUp = up
            $0.generation += 1
        }
    }

    func count(of path: String) -> Int { state.withLock { $0.urls.filter { $0.hasSuffix(path) }.count } }
    var total: Int { state.withLock { $0.urls.count } }

    func connect(to url: URL) async throws -> AsyncThrowingStream<UInt8, Error> {
        let (isUp, generation) = state.withLock { state -> (Bool, Int) in
            state.urls.append(url.path)
            return (state.isUp, state.generation)
        }
        guard isUp else { throw NBBConnectionError.badStatus(nil) }
        let payload = url.path.hasSuffix("version") ? #"{"version":"1.5.2"}"# : #"data: {"resultType":"NONE"}"# + "\n\n"
        let bytes = Array(payload.utf8)
        let isVersion = url.path.hasSuffix("version")
        return AsyncThrowingStream { continuation in
            for byte in bytes { continuation.yield(byte) }
            if isVersion {
                continuation.finish()
                return
            }
            // Stays open until the source goes down (a new generation), as a real stream would.
            let watcher = Task { [weak self] in
                while !Task.isCancelled, let self, self.state.withLock({ $0.generation }) == generation {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
            continuation.onTermination = { _ in watcher.cancel() }
        }
    }
}

@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite("NBB connection", .serialized)
struct NBBConnectionTests {
    @Test func withoutNinjabrainBotOnlyTheStrongholdStreamTriesToConnect() async {
        let source = RecordingSource()
        let connection = NBBConnection(source: source)
        connection.start()
        // The first retry comes 0.5 s after the first refusal.
        #expect(await eventually { source.count(of: "stronghold/events") >= 2 })
        #expect(source.total == source.count(of: "stronghold/events"))
        #expect(connection.runningTaskCount == 1)
        connection.stop()
    }

    @Test func theOtherStreamsFollowTheStrongholdStream() async {
        let source = RecordingSource()
        source.setUp(true)
        let connection = NBBConnection(source: source)
        connection.start()
        #expect(await eventually { connection.isReachable && connection.runningTaskCount == 7 })
        #expect(await eventually { connection.boat != nil && connection.version == "1.5.2" })

        // Ninjabrain Bot quits: the others stop and keep what they had; only the stronghold stream retries.
        source.setUp(false)
        #expect(await eventually { !connection.isReachable && connection.runningTaskCount == 1 })
        #expect(connection.boat != nil)
        let others = source.total - source.count(of: "stronghold/events")
        #expect(await eventually { source.count(of: "stronghold/events") >= 3 })
        #expect(source.total - source.count(of: "stronghold/events") == others)

        // It comes back: everything reconnects, and the version isn't fetched twice.
        source.setUp(true)
        #expect(await eventually { connection.isReachable && connection.runningTaskCount == 6 })
        connection.stop()
        #expect(connection.runningTaskCount == 0)
        #expect(!connection.isRunning)
    }

    @Test func anIdenticalValueAfterAReconnectDoesNotNotifyObservers() async {
        let source = RecordingSource()
        source.setUp(true)
        let connection = NBBConnection(source: source)
        connection.start()
        #expect(await eventually { connection.stronghold != nil && connection.boat != nil })
        let changed = Mutex(false)
        withObservationTracking {
            _ = connection.stronghold
            _ = connection.boat
        } onChange: {
            changed.withLock { $0 = true }
        }
        // A drop and reconnect re-sends the same state.
        source.setUp(false)
        #expect(await eventually { !connection.isReachable })
        source.setUp(true)
        #expect(await eventually { connection.isReachable && connection.runningTaskCount == 6 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!changed.withLock { $0 })
        connection.stop()
    }
}
