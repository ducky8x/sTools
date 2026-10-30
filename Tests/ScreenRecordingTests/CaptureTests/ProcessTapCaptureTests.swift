import CoreAudio
import Foundation
import os
import Testing
@testable import ScreenRecording

/// An app that never makes a sound: the lookup finds no audio process, so the capture keeps looking. Nothing here asks
/// Core Audio anything, so no permission is ever asked for.
private final class SilentApp: Sendable {
    private let lookups = OSAllocatedUnfairLock(initialState: 0)

    var lookupCount: Int { lookups.withLock { $0 } }

    func find(_ target: ProcessTapCapture.Target) -> [AudioObjectID] {
        lookups.withLock { $0 += 1 }
        return []
    }
}

@Suite("Process tap capture")
struct ProcessTapCaptureTests {
    private func capture(_ app: SilentApp) -> ProcessTapCapture {
        ProcessTapCapture(target: .processID(4242), findProcesses: { app.find($0) }, retryInterval: .milliseconds(10))
    }

    /// While the app is silent it keeps looking for its sound; the stop ends the looking (a lookup already under way
    /// as the stop comes may still finish).
    @Test func itLooksForTheAppsSoundUntilTheStop() async throws {
        let app = SilentApp()
        let tap = capture(app)
        try await tap.start { _ in }
        #expect(await waitUntil { app.lookupCount > 2 })
        await tap.stop()
        let atStop = app.lookupCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.lookupCount <= atStop + 1)
    }

    /// A stop before the start (the rig stopped while its sources were still being started) is final: the start looks
    /// for nothing and says it was canceled.
    @Test func aStopBeforeTheStartLooksForNothing() async throws {
        let app = SilentApp()
        let tap = capture(app)
        await tap.stop()
        await #expect(throws: CancellationError.self) { try await tap.start { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.lookupCount == 0)
    }

    /// A stop racing the start on another thread never leaves the capture looking (and so tapping the app once it
    /// makes a sound).
    @Test func aStopRacingTheStartLeavesItIdle() async throws {
        for _ in 0..<30 {
            let app = SilentApp()
            let tap = capture(app)
            async let started: Void? = try? tap.start { _ in }
            async let stopped: Void = tap.stop()
            _ = await (started, stopped)
            let settled = app.lookupCount
            // A capture left looking would look about 15 more times by then.
            try await Task.sleep(for: .milliseconds(150))
            #expect(app.lookupCount <= settled + 1)
        }
    }
}
