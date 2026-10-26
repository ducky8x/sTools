import Foundation
import Synchronization
import Testing
@testable import NBBOverlay

/// The six streams' paths and what a fresh Ninjabrain Bot 1.5.2 sends on each, plus the version.
let freshNinjabrainBot: [String: String] = {
    var values: [String: String] = [:]
    for path in ["blind", "divine", "boat", "information-messages", "all-advancements"] { values["/api/v1/\(path)/events"] = "{}" }
    values["/api/v1/stronghold/events"] = #"{"resultType":"NONE","predictions":[],"eyeThrows":[],"playerPosition":{}}"#
    values["/api/v1/boat/events"] = #"{"boatState":"NONE"}"#
    values["/api/v1/version"] = #"{"version":"1.5.2"}"#
    return values
}()

/// A stronghold result about as long as Ninjabrain Bot sends: five predictions, two throws and the player position.
func strongholdResult(_ seed: Int) -> String {
    let predictions = (0..<5).map { k in
        #"{"chunkX":\#(-41 + k),"chunkZ":\#(108 + seed % 7),"certainty":\#(k == 0 ? 0.5 + Double(seed % 40) / 100 : 0.01),"overworldDistance":\#(1580 + seed)}"#
    }
    let eyeThrows = (0..<2).map { k in
        #"{"xInOverworld":-1374.7,"zInOverworld":81.61,"angle":\#(-80.63 + Double(k)),"angleWithoutCorrection":\#(-80.64 + Double(k)),"correction":0.01,"correctionIncrements":1,"error":0.0022,"type":"NORMAL"}"#
    }
    return #"{"resultType":"TRIANGULATION","predictions":[\#(predictions.joined(separator: ","))],"eyeThrows":[\#(eyeThrows.joined(separator: ","))],"#
        + #""playerPosition":{"xInOverworld":-1374.7,"zInOverworld":81.61,"horizontalAngle":-80.64,"isInOverworld":true,"isInNether":false}}"#
}

private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
    let deadline = SuspendingClock.now + timeout
    while !condition(), SuspendingClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
}

@MainActor
private func waitUntilOnMain(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
    let deadline = SuspendingClock.now + timeout
    while !condition(), SuspendingClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
}

/// Ninjabrain Bot's API over real sockets: `URLSessionEventSource` and `NBBConnection` against `LocalSSEServer`.
@Suite("NBB event streams over HTTP", .serialized)
struct NBBEventStreamTests {
    /// An event comes in whole lines, not a byte at a time: a stronghold result of about 1.5 KB used to cross the stream
    /// byte by byte, about 15 ms before the overlay heard of it.
    @Test func anEventArrivesInLinesNotBytes() async throws {
        let server = try LocalSSEServer(values: freshNinjabrainBot)
        defer { server.stop() }
        let stream = try await URLSessionEventSource().connect(to: server.baseURL.appending(path: "api/v1/stronghold/events"))
        var parser = SSEParser()
        var chunks = 0
        var events: [String] = []
        let result = strongholdResult(1)
        for try await chunk in stream {
            chunks += 1
            events += parser.feed(chunk)
            if events.count == 1 { server.send("/api/v1/stronghold/events", result) }
            if events.count == 2 { break }
        }
        #expect(events == [freshNinjabrainBot["/api/v1/stronghold/events"]!, result])
        #expect(chunks <= 6, "each event is a data line and a blank line: \(chunks) chunks for two events")
    }

    /// Ninjabrain Bot's six streams stay open while the version is asked for: all seven must get through at once
    /// (URLSession's shared session allows six connections to a host, so one of them waited for good).
    @MainActor @Test func theSixStreamsAndTheVersionAllGetThrough() async throws {
        let server = try LocalSSEServer(values: freshNinjabrainBot)
        defer { server.stop() }
        let connection = NBBConnection(baseURL: server.baseURL, source: URLSessionEventSource())
        connection.start()
        defer { connection.stop() }
        let paths = ["stronghold", "blind", "divine", "boat", "information-messages", "all-advancements"]
        await waitUntilOnMain { connection.version != nil && paths.allSatisfy { server.subscribers("/api/v1/\($0)/events") == 1 } }
        #expect(connection.version == "1.5.2")
        #expect(paths.allSatisfy { server.subscribers("/api/v1/\($0)/events") == 1 })
        #expect(connection.boat?.boatState == NBBEvents.BoatState.none && connection.stronghold?.resultType == NBBEvents.ResultType.none)
    }

    /// The same with the six streams open before the version is asked for, which left the version waiting for good.
    @Test func aSeventhRequestGetsThroughWhileSixStreamsAreOpen() async throws {
        let server = try LocalSSEServer(values: freshNinjabrainBot)
        defer { server.stop() }
        let source = URLSessionEventSource()
        let paths = ["stronghold", "blind", "divine", "boat", "information-messages", "all-advancements"]
        var streams: [AsyncThrowingStream<[UInt8], Error>] = []
        for path in paths { streams.append(try await source.connect(to: server.baseURL.appending(path: "api/v1/\(path)/events"))) }
        await waitUntil { paths.allSatisfy { server.subscribers("/api/v1/\($0)/events") == 1 } }
        let version = Task { try await source.connect(to: server.baseURL.appending(path: "api/v1/version")) }
        await waitUntil(timeout: .seconds(5)) { server.connects("/api/v1/version") == 1 }
        version.cancel()
        #expect(server.connects("/api/v1/version") == 1)
        withExtendedLifetime(streams) {}
    }

    /// Ninjabrain Bot quits and comes back on the same port: the streams reconnect and the new state shows.
    @MainActor @Test func reconnectsWhenNinjabrainBotComesBack() async throws {
        let server = try LocalSSEServer(values: freshNinjabrainBot)
        defer { server.stop() }
        let connection = NBBConnection(baseURL: server.baseURL, source: URLSessionEventSource())
        connection.start()
        defer { connection.stop() }
        await waitUntilOnMain { connection.isReachable && server.subscribers("/api/v1/boat/events") == 1 }
        #expect(connection.isReachable)

        // It quits: nothing answers on the port.
        let port = server.port
        server.stop()
        await waitUntilOnMain { !connection.isReachable }
        #expect(!connection.isReachable)

        // It opens again with a result: the stronghold stream finds it within its backoff, and the others follow.
        server.send("/api/v1/stronghold/events", strongholdResult(2))
        server.send("/api/v1/boat/events", #"{"boatState":"VALID","boatAngle":12.5}"#)
        try await server.listen(on: port)
        await waitUntilOnMain { connection.stronghold?.resultType == .triangulation && connection.boat?.boatState == .valid }
        #expect(connection.isReachable && connection.stronghold?.predictions.count == 5)
        #expect(connection.boat?.boatAngle == 12.5)

        // A dropped connection with Ninjabrain Bot still there reconnects too.
        server.dropAll()
        server.send("/api/v1/stronghold/events", strongholdResult(3))
        await waitUntilOnMain { connection.stronghold?.predictions.first?.overworldDistance == 1583 }
        #expect(connection.stronghold?.predictions.first?.overworldDistance == 1583)
    }

    /// Ninjabrain Bot pushes each change; nothing on the way waits for a poll. The fastest of several events reaches
    /// `NBBConnection` well inside any poll interval (the fastest one, so a busy machine can't make it flaky).
    @MainActor @Test func aChangeReachesTheConnectionWithoutWaiting() async throws {
        let server = try LocalSSEServer(values: freshNinjabrainBot)
        defer { server.stop() }
        let connection = NBBConnection(baseURL: server.baseURL, source: URLSessionEventSource())
        connection.start()
        defer { connection.stop() }
        await waitUntilOnMain { connection.stronghold != nil }
        var fastest = Duration.seconds(10)
        for seed in 10..<20 {
            let sentAt = Mutex<ContinuousClock.Instant?>(nil)
            let result = strongholdResult(seed)
            Task.detached {
                sentAt.withLock { $0 = .now }
                server.send("/api/v1/stronghold/events", result)
            }
            await waitUntilOnMain { connection.stronghold?.predictions.first?.overworldDistance == Double(1580 + seed) }
            let arrived = ContinuousClock.now
            if let sent = sentAt.withLock({ $0 }) { fastest = min(fastest, arrived - sent) }
        }
        #expect(fastest < .milliseconds(20), "fastest event took \(fastest)")
    }
}
