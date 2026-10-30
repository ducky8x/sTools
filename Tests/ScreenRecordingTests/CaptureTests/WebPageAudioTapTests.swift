import CoreAudio
import CoreMedia
import Foundation
import os
import Testing
@testable import ScreenRecording

/// Waits (bounded, on a clock a Mac sleep doesn't use up, and generously: a busy Mac stretches every pause) for
/// `condition`.
private func eventually(_ condition: () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + .seconds(20)
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Core Audio's audio processes as a test sets them. Nothing here asks Core Audio anything, so no permission is ever
/// asked for.
private final class FakeWebProcesses: Sendable {
    private let objects = OSAllocatedUnfairLock<[AudioObjectID]>(initialState: [])
    private let lookups = OSAllocatedUnfairLock(initialState: 0)

    func set(_ new: [AudioObjectID]) { objects.withLock { $0 = new } }
    var lookupCount: Int { lookups.withLock { $0 } }

    func find(_ target: ProcessTapCapture.Target) -> [AudioObjectID] {
        lookups.withLock { $0 += 1 }
        return objects.withLock { $0 }
    }
}

/// Taps that exist only in memory: which were made, on which processes, and which are still up.
private final class FakeTaps: Sendable {
    final class Tap: ProcessTapHandle {
        let processes: [AudioObjectID]
        let deliver: @Sendable (AudioChunk) -> Void
        private let stopped = OSAllocatedUnfairLock(initialState: false)
        private let onStop: @Sendable ([AudioObjectID]) -> Void

        init(processes: [AudioObjectID], deliver: @escaping @Sendable (AudioChunk) -> Void, onStop: @escaping @Sendable ([AudioObjectID]) -> Void) {
            self.processes = processes
            self.deliver = deliver
            self.onStop = onStop
        }

        var isStopped: Bool { stopped.withLock { $0 } }

        func stop() {
            let first = stopped.withLock { stopped in
                defer { stopped = true }
                return !stopped
            }
            if first { onStop(processes) }
        }
    }

    private struct State {
        var taps: [Tap] = []
        var events: [String] = []
        var failuresLeft = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var made: [Tap] { state.withLock { $0.taps } }
    /// "make [7]" and "stop [7]", in the order they happened.
    var events: [String] { state.withLock { $0.events } }
    var upNow: [Tap] { made.filter { !$0.isStopped } }

    /// The next `count` attempts to make a tap fail, as when macOS refuses (the permission isn't given yet).
    func failNext(_ count: Int) { state.withLock { $0.failuresLeft = count } }

    func make(_ processes: [AudioObjectID], _ deliver: @escaping @Sendable (AudioChunk) -> Void) throws -> any ProcessTapHandle {
        let refused: Bool = state.withLock { current in
            guard current.failuresLeft > 0 else { return false }
            current.failuresLeft -= 1
            return true
        }
        if refused { throw CaptureError.unavailable("refused") }
        let tap = Tap(processes: processes, deliver: deliver) { [self] stopped in
            state.withLock { $0.events.append("stop \(stopped)") }
        }
        state.withLock { current in
            current.taps.append(tap)
            current.events.append("make \(processes)")
        }
        return tap
    }
}

@Suite("The sound of sTools' web pages, tapped")
struct WebPageAudioTapTests {
    private func capture(_ processes: FakeWebProcesses, _ taps: FakeTaps) -> ProcessTapCapture {
        ProcessTapCapture(target: .ownWebViews, findProcesses: { processes.find($0) }, retryInterval: .milliseconds(10),
                          makeTap: { try taps.make($0, $1) })
    }

    @Test func itTapsNothingWhileThereAreNoWebProcessesAndKeepsLooking() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        #expect(await eventually { processes.lookupCount > 3 })
        #expect(taps.made.isEmpty)
        await capture.stop()
    }

    @Test func itTapsTheProcessesThereAreWhenItStarts() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([9, 7])
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        #expect(taps.made.map(\.processes) == [[7, 9]], "one tap on both, made before the start returned")
        await capture.stop()
        #expect(taps.upNow.isEmpty)
    }

    @Test func aProcessThatAppearsLaterIsTapped() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        processes.set([7])
        #expect(await eventually { taps.made.count == 1 })
        #expect(taps.made.first?.processes == [7])
        await capture.stop()
        #expect(taps.upNow.isEmpty)
    }

    /// A tap listens to the processes it was made for, so a new helper (the page navigated, a second page loaded) needs
    /// a tap on both. The old tap goes down first, so a helper in both is never heard twice.
    @Test func aNewProcessReplacesTheTapWithOneOnBoth() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7])
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        processes.set([7, 9])
        #expect(await eventually { taps.made.count == 2 })
        #expect(taps.events == ["make [7]", "stop [7]", "make [7, 9]"])
        #expect(taps.upNow.count == 1)
        await capture.stop()
        #expect(taps.upNow.isEmpty)
    }

    @Test func anUnchangedSetKeepsItsTap() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7, 9])
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        let lookups = processes.lookupCount
        #expect(await eventually { processes.lookupCount >= lookups + 8 })
        #expect(taps.events == ["make [7, 9]"], "looked again eight times and left the tap alone")
        await capture.stop()
    }

    @Test func whenTheProcessesGoTheTapGoesAndWhenTheyReturnANewOneComes() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7])
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        processes.set([])
        #expect(await eventually { taps.upNow.isEmpty })
        let lookups = processes.lookupCount
        #expect(await eventually { processes.lookupCount >= lookups + 5 })
        #expect(taps.made.count == 1, "no tap is made on nothing")
        processes.set([12])
        #expect(await eventually { taps.made.count == 2 })
        #expect(taps.events == ["make [7]", "stop [7]", "make [12]"])
        await capture.stop()
        #expect(taps.upNow.isEmpty)
    }

    /// No stray taps: the stop takes the tap down, and nothing looks or taps afterwards.
    @Test func theStopTakesTheTapDownAndEndsTheLooking() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7])
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        await capture.stop()
        #expect(taps.upNow.isEmpty)
        let lookups = processes.lookupCount
        processes.set([7, 9])
        try await Task.sleep(for: .milliseconds(150))
        #expect(processes.lookupCount <= lookups + 1, "a lookup under way as the stop came may finish")
        #expect(taps.made.count == 1, "nothing was tapped after the stop")
    }

    /// A stop before the start is final: the start looks for nothing and says it was canceled.
    @Test func aStopBeforeTheStartTapsNothing() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7])
        let capture = capture(processes, taps)
        await capture.stop()
        await #expect(throws: CancellationError.self) { try await capture.start { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(taps.made.isEmpty)
        #expect(processes.lookupCount == 0)
    }

    /// A stop racing the start on another thread never leaves a tap up, whichever gets there first.
    @Test func aStopRacingTheStartLeavesNoTapUp() async throws {
        for _ in 0..<30 {
            let processes = FakeWebProcesses(), taps = FakeTaps()
            processes.set([7])
            let capture = capture(processes, taps)
            async let started: Void? = try? capture.start { _ in }
            async let stopped: Void = capture.stop()
            _ = await (started, stopped)
            // A lookup that was under way may still bring a tap up, and takes it down again at once.
            #expect(await eventually { taps.upNow.isEmpty })
            try await Task.sleep(for: .milliseconds(40))
            #expect(taps.upNow.isEmpty)
        }
    }

    /// macOS can refuse a tap (App audio isn't given yet): the start doesn't fail and the capture tries again, so the
    /// sound is there once the permission is.
    @Test func aTapMacOSRefusesIsTriedAgain() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7])
        taps.failNext(2)
        let capture = capture(processes, taps)
        try await capture.start { _ in }
        #expect(taps.made.isEmpty)
        #expect(await eventually { taps.made.count == 1 })
        #expect(taps.made.first?.processes == [7])
        await capture.stop()
        #expect(taps.upNow.isEmpty)
    }

    @Test func soundFromTheTapReachesTheRecording() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7])
        let capture = capture(processes, taps)
        let received = OSAllocatedUnfairLock<[AudioChunk]>(initialState: [])
        try await capture.start { chunk in received.withLock { $0.append(chunk) } }
        let chunk = AudioChunk(samples: [0.1, -0.1, 0.2, -0.2], sampleRate: 48_000, channelCount: 2, hostTime: .seconds(5))
        taps.made.first?.deliver(chunk)
        #expect(received.withLock { $0.map(\.samples) } == [[0.1, -0.1, 0.2, -0.2]])
        await capture.stop()
    }

    /// An app's sound is still tapped once and left alone: its processes don't come and go like a web page's helpers,
    /// and the looking ends when the tap is up.
    @Test func anAppsTapIsMadeOnceAndTheLookingEnds() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        let capture = ProcessTapCapture(target: .bundleID("com.example.App"), findProcesses: { processes.find($0) },
                                        retryInterval: .milliseconds(10), makeTap: { try taps.make($0, $1) })
        try await capture.start { _ in }
        processes.set([3])
        #expect(await eventually { taps.made.count == 1 })
        let lookups = processes.lookupCount
        processes.set([3, 4])
        try await Task.sleep(for: .milliseconds(100))
        #expect(taps.made.count == 1)
        #expect(processes.lookupCount <= lookups + 1)
        await capture.stop()
        #expect(taps.upNow.isEmpty)
    }

    /// Where macOS can't say whose a web helper is, nothing may be tapped: the start says so, instead of leaving a
    /// track that is silent for no reason anyone can see.
    @Test func withoutAnswerToWhoseHelpersTheyAreItSaysSoAndTapsNothing() async throws {
        let processes = FakeWebProcesses(), taps = FakeTaps()
        processes.set([7])
        let capture = ProcessTapCapture(target: .ownWebViews, findProcesses: { processes.find($0) }, retryInterval: .milliseconds(10),
                                        canTellWhoseHelpersTheyAre: false, makeTap: { try taps.make($0, $1) })
        await #expect(throws: CaptureError.self) { try await capture.start { _ in } }
        #expect(taps.made.isEmpty)
        #expect(processes.lookupCount == 0)
    }
}
