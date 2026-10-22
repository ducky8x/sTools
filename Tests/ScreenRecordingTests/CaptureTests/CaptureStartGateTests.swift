import Foundation
import os
import Testing
@testable import ScreenRecording

/// A source made of the gate and one thing its start brings up after an await, the way ScreenCaptureKit's stream, a
/// camera's session, a browser page's window and a process tap come up. Its stop ignores what isn't up yet, as the
/// real ones' stops did.
private final class GatedSource: @unchecked Sendable {
    let gate = CaptureStartGate()
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let bringUpTakes: Duration

    init(bringUpTakes: Duration) {
        self.bringUpTakes = bringUpTakes
    }

    var isRunning: Bool { running.withLock { $0 } }

    func start() async throws {
        try gate.check()
        await uncancellableWait(bringUpTakes)
        try gate.check()
        await uncancellableWait(bringUpTakes)
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
        let source = GatedSource(bringUpTakes: .milliseconds(10))
        try await source.start()
        #expect(source.isRunning)
        await source.stop()
        #expect(!source.isRunning)
    }

    /// A stop before the start: the start brings nothing up and says it was canceled.
    @Test func aStopBeforeTheStartBringsNothingUp() async {
        let source = GatedSource(bringUpTakes: .milliseconds(10))
        await source.stop()
        await #expect(throws: CancellationError.self) { try await source.start() }
        #expect(!source.isRunning)
    }

    /// A stop while the start waits on its first await, or on its last one (what it brings up finishes after the
    /// stop): either way nothing is left running once the start returns.
    @Test(arguments: [20, 70])
    func aStopDuringTheStartLeavesNothingRunning(stopAfterMilliseconds: Int) async {
        let source = GatedSource(bringUpTakes: .milliseconds(50))
        let starting = Task { try await source.start() }
        try? await Task.sleep(for: .milliseconds(stopAfterMilliseconds))
        await source.stop()
        let result = await starting.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!source.isRunning)
        try? await Task.sleep(for: .milliseconds(150))
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
