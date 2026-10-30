import Foundation
import os
import Testing
@testable import ScreenRecording

/// A source made of the gate and one thing its start brings up after an await, the way ScreenCaptureKit's stream, a
/// camera's session, a browser page's window and a process tap come up. Its stop ignores what isn't up yet, as the
/// real ones' stops did. Each of its two awaits can be held until the test opens a gate (`StartGate`), so a stop can be
/// made to come at either one without a timer.
private final class GatedSource: @unchecked Sendable {
    let gate = CaptureStartGate()
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let firstWait: StartGate?
    private let secondWait: StartGate?
    private let begun = OSAllocatedUnfairLock(initialState: 0)

    init(firstWait: StartGate? = nil, secondWait: StartGate? = nil) {
        self.firstWait = firstWait
        self.secondWait = secondWait
    }

    var isRunning: Bool { running.withLock { $0 } }
    /// How many of its awaits the start has reached.
    var awaitsReached: Int { begun.withLock { $0 } }

    func start() async throws {
        try gate.check()
        begun.withLock { $0 += 1 }
        await firstWait?.wait()
        try gate.check()
        begun.withLock { $0 += 1 }
        await secondWait?.wait()
        running.withLock { $0 = true }
        try await gate.finish { await self.tearDown() }
    }

    func stop() async {
        gate.close()
        await tearDown()
    }

    private func tearDown() async {
        running.withLock { $0 = false }
    }
}

@Suite("Capture start gate")
struct CaptureStartGateTests {
    @Test func aStartWithoutAStopRuns() async throws {
        let source = GatedSource()
        try await source.start()
        #expect(source.isRunning)
        await source.stop()
        #expect(!source.isRunning)
    }

    /// A stop before the start: the start brings nothing up and says it was canceled.
    @Test func aStopBeforeTheStartBringsNothingUp() async {
        let source = GatedSource()
        await source.stop()
        await #expect(throws: CancellationError.self) { try await source.start() }
        #expect(!source.isRunning)
    }

    /// A stop while the start waits on its first await, or on its last one (what it brings up finishes after the
    /// stop): either way nothing is left running once the start returns. The start is held at the await the stop is
    /// meant to hit, so it hits it however busy the Mac is.
    @Test(arguments: [1, 2])
    func aStopDuringTheStartLeavesNothingRunning(heldAtAwait: Int) async {
        let first = StartGate(), second = StartGate()
        let source = GatedSource(firstWait: first, secondWait: second)
        let starting = Task { try await source.start() }
        if heldAtAwait == 2 { first.open() }
        #expect(await waitUntil { source.awaitsReached == heldAtAwait }, "the start reached await \(heldAtAwait)")
        await source.stop()
        first.open()
        second.open()
        let result = await starting.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!source.isRunning)
    }

    @Test func closingIsForGood() throws {
        let gate = CaptureStartGate()
        #expect(!gate.isClosed)
        try gate.check()
        gate.close()
        gate.close()
        #expect(gate.isClosed)
        #expect(throws: CancellationError.self) { try gate.check() }
    }
}
