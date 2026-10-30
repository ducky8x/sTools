import Foundation
import Synchronization
import Testing
@testable import NBBOverlay

/// The six streams' paths, as they end each URL.
private let streamPaths = ["stronghold", "blind", "divine", "boat", "information-messages", "all-advancements"].map { "\($0)/events" }

/// Records every URL asked for. Refuses while `isUp` is false (Ninjabrain Bot not running); otherwise sends each
/// endpoint's state once and keeps the stream open, like Ninjabrain Bot, until told to drop everything.
///
/// With `holdsStronghold` the stronghold stream opens, and so brings the other five up, but says nothing until
/// `releaseStronghold()`. The other streams start when the stronghold stream connects, not when it speaks, so which stream's
/// first value comes first is up to the timing; this makes the stronghold's the last.
private final class RecordingSource: NBBEventSource, @unchecked Sendable {
    private struct State {
        var urls: [String] = []
        var isUp = false
        var generation = 0
        var holdsStronghold: Bool
        /// The stronghold stream's opening message, waiting for its release.
        var held: (continuation: AsyncThrowingStream<[UInt8], Error>.Continuation, bytes: [UInt8])?
    }

    private let state: Mutex<State>

    init(holdsStronghold: Bool = false) { state = Mutex(State(holdsStronghold: holdsStronghold)) }

    func setUp(_ up: Bool) {
        state.withLock {
            $0.isUp = up
            $0.generation += 1
        }
    }

    /// Lets the held stronghold stream speak, and every later one speak when it opens.
    func releaseStronghold() {
        let held = state.withLock { state -> (continuation: AsyncThrowingStream<[UInt8], Error>.Continuation, bytes: [UInt8])? in
            state.holdsStronghold = false
            defer { state.held = nil }
            return state.held
        }
        if let held { held.continuation.yield(held.bytes) }
    }

    func count(of path: String) -> Int { state.withLock { $0.urls.filter { $0.hasSuffix(path) }.count } }
    var total: Int { state.withLock { $0.urls.count } }

    func connect(to url: URL) async throws -> AsyncThrowingStream<[UInt8], Error> {
        let (isUp, generation) = state.withLock { state -> (Bool, Int) in
            state.urls.append(url.path)
            return (state.isUp, state.generation)
        }
        guard isUp else { throw NBBConnectionError.badStatus(nil) }
        let payload = url.path.hasSuffix("version") ? #"{"version":"1.5.2"}"# : #"data: {"resultType":"NONE"}"# + "\n\n"
        let bytes = Array(payload.utf8)
        let isVersion = url.path.hasSuffix("version")
        let isStronghold = url.path.hasSuffix("stronghold/events")
        return AsyncThrowingStream { continuation in
            let holds = isStronghold && state.withLock { state -> Bool in
                if state.holdsStronghold { state.held = (continuation, bytes) }
                return state.holdsStronghold
            }
            if !holds { continuation.yield(bytes) }
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
private func eventually(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = SuspendingClock.now + timeout
    while SuspendingClock.now < deadline {
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

    /// How many of the six streams have brought a value, as `onChange` finds them.
    private func valuesIn(_ connection: NBBConnection) -> Int {
        [connection.stronghold != nil, connection.blind != nil, connection.divine != nil, connection.boat != nil,
         connection.informationMessages != nil, connection.allAdvancements != nil].filter { $0 }.count
    }

    /// `onChange` comes after the new value is in place, so the overlay can draw it in the same turn, and not for a value
    /// that's the same as the last. Each stream brings one value, so the call for the k-th finds k values in place, whichever
    /// stream is k-th: the five others start when the stronghold stream connects, and any of the six can speak first. A call
    /// made before its value was set would find one fewer.
    @Test(arguments: [false, true])
    func onChangeComesAfterTheNewValueIsSet(strongholdSpeaksLast: Bool) async {
        let source = RecordingSource(holdsStronghold: strongholdSpeaksLast)
        source.setUp(true)
        let connection = NBBConnection(source: source)
        var found: [Int] = []
        connection.onChange = { found.append(self.valuesIn(connection)) }
        connection.start()
        if strongholdSpeaksLast {
            #expect(await eventually {
                connection.blind != nil && connection.divine != nil && connection.boat != nil
                    && connection.informationMessages != nil && connection.allAdvancements != nil
            })
            #expect(connection.stronghold == nil && found == [1, 2, 3, 4, 5], "the stronghold stream has said nothing yet")
            source.releaseStronghold()
        }
        #expect(await eventually { self.valuesIn(connection) == 6 })
        #expect(found == [1, 2, 3, 4, 5, 6], "every call found its own value in place, and no later one")
        #expect(connection.stronghold?.resultType == NBBEvents.ResultType.none)
        if strongholdSpeaksLast { #expect(found.last == 6, "the stronghold's call found the stronghold") }

        // Every stream asks again after a drop and is sent its state again; none of it differs from the last.
        let count = found.count
        source.setUp(false)
        #expect(await eventually { !connection.isReachable })
        source.setUp(true)
        #expect(await eventually { connection.isReachable && connection.runningTaskCount == 6 })
        #expect(await eventually { streamPaths.allSatisfy { source.count(of: $0) >= 2 } }, "all six streams asked again")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(found.count == count, "a reconnect re-sent the same values")
        connection.stop()
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
