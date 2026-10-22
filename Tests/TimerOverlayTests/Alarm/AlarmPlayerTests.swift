import AVFoundation
import Foundation
import STDesign
import Testing
@testable import TimerOverlay

// MARK: - Fakes (private to this file; nothing here plays a sound or starts an audio engine)

@MainActor
private final class FakeClock: TimerClock {
    var time: TimeInterval = 1000
    func now() -> TimeInterval { time }
}

@MainActor
private final class FakeWake: TimerScheduledWake {
    let due: TimeInterval
    let action: @MainActor () -> Void
    var isCancelled = false
    var hasFired = false

    init(due: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.due = due
        self.action = action
    }

    func cancel() { isCancelled = true }
}

/// Wakes only when the test moves the clock past them.
@MainActor
private final class FakeScheduler: TimerScheduling {
    let clock: FakeClock
    private(set) var wakes: [FakeWake] = []
    private(set) var mostPendingAtOnce = 0

    init(clock: FakeClock) { self.clock = clock }

    var pending: [FakeWake] { wakes.filter { !$0.isCancelled && !$0.hasFired } }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledWake {
        let wake = FakeWake(due: clock.time + max(0, delay), action: action)
        wakes.append(wake)
        mostPendingAtOnce = max(mostPendingAtOnce, pending.count)
        return wake
    }

    /// Moves the clock forward to `time`, firing each wake due by then at its own due time.
    func advance(to time: TimeInterval) {
        while let next = pending.filter({ $0.due <= time + 1e-9 }).min(by: { $0.due < $1.due }) {
            clock.time = max(clock.time, next.due)
            next.hasFired = true
            next.action()
        }
        clock.time = max(clock.time, time)
    }

    func advance(by seconds: TimeInterval) { advance(to: clock.time + seconds) }
}

private struct FakeFailure: Error {}

/// An engine that records what it's asked to play and reports items only when the test says so.
@MainActor
private final class FakeEngine: AlarmAudioEngine {
    let sound: URL
    let soundFrameCount: Int
    let sampleRate: Double
    var onInterruption: (@MainActor () -> Void)?
    var startFails = false
    private(set) var items: [AlarmPlaybackItem] = []
    private(set) var volume: Float?
    private(set) var isRunning = false
    private(set) var tap: (@Sendable (AlarmRenderedBuffer) -> Void)?
    private(set) var stops = 0
    private var onItemPlayed: (@MainActor (Int) -> Void)?

    init(sound: URL, frames: Int, rate: Double) {
        self.sound = sound
        soundFrameCount = frames
        sampleRate = rate
    }

    func play(_ items: [AlarmPlaybackItem], volume: Float, onItemPlayed: @escaping @MainActor (Int) -> Void) throws {
        self.items = items
        self.volume = volume
        self.onItemPlayed = onItemPlayed
        if startFails { throw FakeFailure() }
        isRunning = true
    }

    func installTap(_ handler: @escaping @Sendable (AlarmRenderedBuffer) -> Void) { tap = handler }
    func removeTap() { tap = nil }

    /// Like a real node, a stop reports every item it cut short, at once.
    func stop() {
        stops += 1
        isRunning = false
        let report = onItemPlayed
        onItemPlayed = nil
        for index in items.indices { report?(index) }
    }

    /// The node has played item `index` out.
    func played(_ index: Int) { onItemPlayed?(index) }
    func render(_ buffer: AlarmRenderedBuffer) { tap?(buffer) }
    func systemStopped() { onInterruption?() }
}

@MainActor
private final class FakeEngines: AlarmEngineMaking {
    private final class Weak {
        weak var engine: FakeEngine?
        init(_ engine: FakeEngine) { self.engine = engine }
    }

    /// Each sound's length by file name; anything else lasts 1.5 s, like Ping.
    var lengths: [String: TimeInterval] = [:]
    var unreadable: Set<String> = []
    var startFails = false
    let rate = 48_000.0
    private(set) var requested: [URL] = []
    private var made: [Weak] = []

    func makeEngine(for sound: URL) throws -> any AlarmAudioEngine {
        requested.append(sound)
        if unreadable.contains(sound.lastPathComponent) { throw FakeFailure() }
        let length = lengths[sound.lastPathComponent] ?? 1.5
        let engine = FakeEngine(sound: sound, frames: Int((length * rate).rounded()), rate: rate)
        engine.startFails = startFails
        made.append(Weak(engine))
        return engine
    }

    var madeCount: Int { made.count }
    /// The engines that still exist. Once the player lets one go, nothing holds it.
    var alive: [FakeEngine] { made.compactMap(\.engine) }
    /// The newest engine still alive.
    var current: FakeEngine? { alive.last }
}

/// What the player reported, and when on the clock.
@MainActor
private final class Reports {
    var rings: [(index: Int, at: TimeInterval)] = []
    var ends: [TimeInterval] = []
}

@MainActor
private final class Rig {
    let clock = FakeClock()
    let scheduler: FakeScheduler
    let engines = FakeEngines()
    let player: AlarmPlayer
    let reports = Reports()

    init() {
        scheduler = FakeScheduler(clock: clock)
        player = AlarmPlayer(engines: engines, clock: clock, scheduler: scheduler)
    }

    func ring(_ name: String = "Ping.aiff", volume: Double = 0.8, schedule: AlarmSchedule = pingThreeTimes) {
        let reports = reports
        let clock = clock
        player.ring(URL(filePath: "/sounds/\(name)"), volume: volume, schedule: schedule,
                    onRing: { reports.rings.append(($0, clock.now())) }, onEnd: { reports.ends.append(clock.now()) })
    }

    func preview(_ name: String = "Ping.aiff", rings: Int = 3) {
        let reports = reports
        let clock = clock
        player.preview(URL(filePath: "/sounds/\(name)"), volume: 0.5, rings: rings, onEnd: { reports.ends.append(clock.now()) })
    }

    /// Plays every item out in order, each at its planned end.
    func playEverything(start: TimeInterval) {
        guard let engine = engines.current else { return }
        var end = 0
        let items = engine.items
        let rate = engine.sampleRate
        for index in items.indices {
            end += items[index].frameCount
            scheduler.advance(to: start + Double(end) / rate)
            engines.current?.played(index)
        }
    }
}

private let pingThreeTimes = AlarmSchedule(
    soundLength: 1.5, rings: 3, leave: .afterLastRing, leaveAfterLastRing: 2, leaveAfterZero: 5, whileRinging: .pulsePerRing)

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

// MARK: - The plan

@Suite("Alarm playback plan")
struct AlarmPlaybackPlanTests {
    @Test func pingThreeTimesIsALeadInThenRingsAndGaps() {
        let plan = AlarmPlaybackPlan(schedule: pingThreeTimes, soundFrames: 72_000, sampleRate: 48_000)
        #expect(plan.items == [
            .silence(frames: 480), .sound(start: 0, count: 72_000),
            .silence(frames: 16_800), .sound(start: 0, count: 72_000),
            .silence(frames: 16_800), .sound(start: 0, count: 72_000),
        ])
        #expect(plan.marks.map(\.event) == [.ring(0), .ring(1), .ring(2), .end])
        #expect(plan.marks.map(\.afterItem) == [0, 2, 4, 5])
        #expect(zip(plan.marks.map(\.time), [0.01, 1.86, 3.71, 5.21]).allSatisfy { near($0, $1) })
        #expect(near(plan.duration, 5.21))
    }

    @Test func eachRingStartsAtItsScheduledTime() {
        let plan = AlarmPlaybackPlan(schedule: pingThreeTimes, soundFrames: 72_000, sampleRate: 48_000)
        for case (let mark, let start) in zip(plan.marks.dropLast(), pingThreeTimes.ringStarts) {
            let framesBefore = plan.items[...mark.afterItem].reduce(0) { $0 + $1.frameCount }
            #expect(framesBefore == 480 + Int((start * 48_000).rounded()))
        }
    }

    @Test func aSetTimeAfterZeroCutsTheLastRingWithAFade() {
        let schedule = AlarmSchedule(
            soundLength: 1.5, rings: 3, leave: .afterZero, leaveAfterLastRing: 2, leaveAfterZero: 5,
            whileRinging: .pulsePerRing)
        let plan = AlarmPlaybackPlan(schedule: schedule, soundFrames: 72_000, sampleRate: 48_000)
        // The third ring starts at 3.7 s and the alarm ends at 5 s: 1.3 s of it, the last 20 ms fading.
        #expect(Array(plan.items.suffix(2)) == [.sound(start: 0, count: 61_440), .fadeOut(start: 61_440, count: 960)])
        #expect(near(plan.duration, 5.01))
        #expect(plan.marks.last == AlarmPlaybackPlan.Mark(event: .end, afterItem: plan.items.count - 1, time: plan.duration))
    }

    @Test func aRingNeverRunsIntoTheNextOne() {
        // The schedule was made for a 1 s sound, but the file lasts 2 s: each ring stops, fading, as the next starts.
        let schedule = AlarmSchedule(
            soundLength: 1, rings: 2, leave: .afterLastRing, leaveAfterLastRing: 0, leaveAfterZero: 5,
            whileRinging: .pulsePerRing)
        let plan = AlarmPlaybackPlan(schedule: schedule, soundFrames: 96_000, sampleRate: 48_000)
        #expect(plan.items == [
            .silence(frames: 480), .sound(start: 0, count: 63_840), .fadeOut(start: 63_840, count: 960),
            .sound(start: 0, count: 47_040), .fadeOut(start: 47_040, count: 960),
        ])
        #expect(plan.marks.map(\.afterItem) == [0, 2, 4])
    }

    @Test func aShortSoundLeavesLongerGapsAndLongOnesAreSplit() {
        // The schedule was made for a 3 s sound, but the file lasts 0.5 s.
        let schedule = AlarmSchedule(
            soundLength: 3, rings: 2, leave: .afterLastRing, leaveAfterLastRing: 0, leaveAfterZero: 5,
            whileRinging: .pulsePerRing)
        let plan = AlarmPlaybackPlan(schedule: schedule, soundFrames: 24_000, sampleRate: 48_000)
        let silences = plan.items.compactMap { item -> Int? in if case .silence(let frames) = item { frames } else { nil } }
        #expect(silences.allSatisfy { $0 <= 48_000 }, "no silence item is longer than a second")
        #expect(silences.dropFirst().reduce(0, +) == Int(((3.35 - 0.5) * 48_000).rounded()))
        #expect(near(plan.marks[1].time, 0.01 + 3.35))
    }

    @Test func oneRingIsTheSoundOnceAfterTheLeadIn() {
        let schedule = AlarmSchedule(
            soundLength: 0.9, rings: 1, leave: .afterLastRing, leaveAfterLastRing: 0, leaveAfterZero: 1,
            whileRinging: .timesUpLookOnly)
        let plan = AlarmPlaybackPlan(schedule: schedule, soundFrames: 39_690, sampleRate: 44_100)
        #expect(plan.items == [.silence(frames: 441), .sound(start: 0, count: 39_690)])
        #expect(plan.marks.map(\.event) == [.ring(0), .end])
    }
}

// MARK: - The player

@MainActor
@Suite("Alarm player")
struct AlarmPlayerTests {
    // MARK: Cost: an engine only while something plays

    @Test func nothingExistsUntilSomethingPlays() {
        let rig = Rig()
        rig.player.onRenderedBuffer = { _ in }
        #expect(rig.engines.madeCount == 0)
        #expect(!rig.player.isPlaying)
        #expect(!rig.player.hasEngine)
        #expect(rig.scheduler.pending.isEmpty)
    }

    @Test func aRingBuildsOneEngineForTheSoundAndPlaysThePlan() throws {
        let rig = Rig()
        rig.ring(volume: 0.8)

        #expect(rig.engines.requested.map(\.lastPathComponent) == ["Ping.aiff"])
        let engine = try #require(rig.engines.current)
        #expect(engine.items == AlarmPlaybackPlan(schedule: pingThreeTimes, soundFrames: 72_000, sampleRate: 48_000).items)
        #expect(engine.volume == 0.8)
        #expect(engine.isRunning)
        #expect(rig.player.isPlaying)
        #expect(rig.player.hasEngine)
    }

    @Test func eachRingIsReportedAsTheEngineReachesItAndTheEngineGoesWithTheLastSound() throws {
        let rig = Rig()
        let start = rig.clock.time
        rig.ring()

        rig.playEverything(start: start)

        #expect(rig.reports.rings.map(\.index) == [0, 1, 2])
        #expect(zip(rig.reports.rings.map(\.at), [0.01, 1.86, 3.71]).allSatisfy { near($0 - start, $1) })
        #expect(rig.reports.ends.count == 1)
        #expect(near(try #require(rig.reports.ends.first) - start, 5.21))
        #expect(rig.engines.alive.isEmpty, "the engine is let go as the last sound has been heard")
        #expect(!rig.player.isPlaying)
        #expect(rig.scheduler.pending.isEmpty)
    }

    @Test func withoutTheEnginesWordTheEngineIsGoneHalfASecondAfterTheLastSound() throws {
        let rig = Rig()
        let start = rig.clock.time
        rig.ring()

        rig.scheduler.advance(to: start + 5.21 + AlarmPlayer.lateness - 0.001)
        #expect(rig.engines.alive.count == 1, "still within its half second")
        rig.scheduler.advance(to: start + 5.21 + AlarmPlayer.lateness)

        #expect(rig.engines.alive.isEmpty)
        #expect(rig.reports.rings.map(\.index) == [0, 1, 2], "the clock reported the rings the engine didn't")
        #expect(zip(rig.reports.rings.map(\.at), [0.51, 2.36, 4.21]).allSatisfy { near($0 - start, $1) })
        #expect(rig.reports.ends.count == 1)
        #expect(!rig.player.isPlaying)
    }

    @Test func stopLetsTheEngineGoAtOnceAndNothingIsReportedAfter() {
        let rig = Rig()
        rig.ring()
        rig.scheduler.advance(by: 0.5)
        rig.engines.current?.played(0)
        #expect(rig.reports.rings.count == 1)

        rig.player.stop()

        #expect(rig.engines.alive.isEmpty)
        #expect(!rig.player.isPlaying)
        #expect(rig.scheduler.pending.isEmpty)
        rig.scheduler.advance(by: 30)
        #expect(rig.reports.rings.count == 1)
        #expect(rig.reports.ends.isEmpty, "stopping isn't ending")
    }

    @Test func aPreviewPlaysTheRingsAndLetsItsEngineGoWhenItEnds() throws {
        let rig = Rig()
        let start = rig.clock.time
        rig.preview(rings: 2)
        do {
            // Scoped, so the test holds no engine once the player lets it go.
            let engine = try #require(rig.engines.current)
            #expect(engine.items.filter { if case .sound = $0 { true } else { false } }.count == 2)
            #expect(engine.volume == 0.5)
        }

        rig.playEverything(start: start)

        #expect(rig.reports.ends.count == 1)
        #expect(rig.engines.alive.isEmpty)
        #expect(rig.reports.rings.isEmpty, "a preview doesn't pulse anything")
    }

    @Test func aPreviewNobodyHearsEndIsGoneHalfASecondLater() {
        let rig = Rig()
        let start = rig.clock.time
        rig.preview(rings: 1)
        rig.scheduler.advance(to: start + 0.01 + 1.5 + AlarmPlayer.lateness)
        #expect(rig.engines.alive.isEmpty)
        #expect(rig.reports.ends.count == 1)
    }

    @Test(arguments: [(AlarmSchedule.Cue.chime, STSound.chime), (.tick, .tick)])
    func aCuePlaysSToolsSoundOnceAtTheAlarmsVolume(_ cue: AlarmSchedule.Cue, _ sound: STSound) throws {
        let rig = Rig()
        rig.engines.lengths = ["chime.wav": 0.9, "tick.wav": 0.025]
        let start = rig.clock.time

        rig.player.playCue(cue, volume: 0.6)

        #expect(rig.engines.requested == [try #require(sound.resourceURL)])
        do {
            let engine = try #require(rig.engines.current)
            #expect(engine.volume == 0.6)
            #expect(engine.items.filter { if case .sound = $0 { true } else { false } }.count == 1)
        }
        rig.playEverything(start: start)
        #expect(rig.engines.alive.isEmpty)
        #expect(!rig.player.isPlaying)
    }

    @Test func startingSomethingStopsWhatWasPlaying() {
        let rig = Rig()
        rig.preview()
        rig.ring()

        #expect(rig.engines.madeCount == 2)
        #expect(rig.engines.alive.count == 1, "the preview's engine is gone")
        #expect(rig.reports.ends.isEmpty, "the preview was stopped, not ended")
        #expect(rig.scheduler.pending.count == 1)
    }

    @Test func atMostOneWakeIsPendingAndNoneOnceItsOver() {
        let rig = Rig()
        let start = rig.clock.time
        rig.ring()
        rig.playEverything(start: start)
        rig.preview()
        rig.player.stop()
        rig.player.playCue(.tick, volume: 1)
        rig.scheduler.advance(by: 10)

        #expect(rig.scheduler.mostPendingAtOnce == 1)
        #expect(rig.scheduler.pending.isEmpty)
        #expect(rig.engines.alive.isEmpty)
    }

    // MARK: The recording tap

    @Test func theTapExistsOnlyWhileAListenerIsSetAndSomethingPlays() {
        let rig = Rig()
        rig.ring()
        #expect(rig.engines.current?.tap == nil, "nobody listens")

        rig.player.onRenderedBuffer = { _ in }
        #expect(rig.engines.current?.tap != nil)
        rig.player.onRenderedBuffer = nil
        #expect(rig.engines.current?.tap == nil)

        rig.player.onRenderedBuffer = { _ in }
        rig.player.stop()
        #expect(rig.engines.alive.isEmpty, "the tap went with the engine")

        rig.ring()
        #expect(rig.engines.current?.tap != nil, "a listener set beforehand taps the next alarm from its start")
    }

    @Test func renderedBuffersReachTheListener() {
        let rig = Rig()
        let received = Received()
        rig.player.onRenderedBuffer = { buffer in received.add(buffer) }
        rig.ring()
        let buffer = AlarmRenderedBuffer(samples: [0.1, -0.1, 0.2, -0.2], sampleRate: 48_000, channelCount: 2, hostTime: 42)

        rig.engines.current?.render(buffer)

        #expect(received.all == [buffer])
        #expect(buffer.frameCount == 2)
    }

    // MARK: When the sound can't play

    @Test func aSoundThatCantBeOpenedFallsBackToPing() {
        let rig = Rig()
        rig.engines.unreadable = ["Gone.wav"]
        rig.ring("Gone.wav")
        #expect(rig.engines.requested.map(\.lastPathComponent) == ["Gone.wav", AlarmSound.fallback().url.lastPathComponent])
        #expect(rig.engines.alive.count == 1)
    }

    @Test func withNoSoundAtAllTheRingsStillComeOnTime() throws {
        let rig = Rig()
        rig.engines.unreadable = ["Gone.wav", AlarmSound.fallback().url.lastPathComponent]
        let start = rig.clock.time
        rig.ring("Gone.wav")
        #expect(rig.engines.alive.isEmpty)
        #expect(rig.player.isPlaying)

        rig.scheduler.advance(by: 10)

        #expect(rig.reports.rings.map(\.index) == [0, 1, 2])
        #expect(zip(rig.reports.rings.map(\.at), [0.01, 1.86, 3.71]).allSatisfy { near($0 - start, $1) })
        #expect(near(try #require(rig.reports.ends.first) - start, 5.21))
    }

    @Test func anEngineThatCantStartIsLetGoAndTheRingsStillCome() {
        let rig = Rig()
        rig.engines.startFails = true
        rig.ring()
        #expect(rig.engines.alive.isEmpty)
        rig.scheduler.advance(by: 10)
        #expect(rig.reports.rings.map(\.index) == [0, 1, 2])
        #expect(rig.reports.ends.count == 1)
    }

    @Test func anEngineTheSystemStopsIsLetGoAndTheRestFollowsTheClock() {
        let rig = Rig()
        let start = rig.clock.time
        rig.ring()
        rig.scheduler.advance(to: start + 0.01)
        rig.engines.current?.played(0)
        rig.scheduler.advance(to: start + 1.0)

        rig.engines.current?.systemStopped()

        #expect(rig.engines.alive.isEmpty)
        #expect(rig.reports.rings.map(\.index) == [0], "the stop's early reports count for nothing")
        rig.scheduler.advance(by: 10)
        #expect(rig.reports.rings.map(\.index) == [0, 1, 2])
        #expect(zip(rig.reports.rings.map(\.at), [0.01, 1.86, 3.71]).allSatisfy { near($0 - start, $1) })
        #expect(rig.reports.ends.count == 1)
    }

    @Test func anItemReportedBeforeItsTimeIsIgnored() {
        let rig = Rig()
        let start = rig.clock.time
        rig.ring()
        rig.scheduler.advance(to: start + 0.5)
        rig.engines.current?.played(2)
        #expect(rig.reports.rings.map(\.index) == [0], "ring 0's time had come; ring 1's hadn't")

        rig.scheduler.advance(to: start + 1.86)
        rig.engines.current?.played(2)
        #expect(rig.reports.rings.map(\.index) == [0, 1])
    }

    // MARK: Volume

    @Test(arguments: [(0.8, Float(0.8)), (0, 0), (1, 1), (1.7, 1), (-0.2, 0), (.nan, 0), (.infinity, 1)])
    func theVolumeIsTheAlarmsOwnKeptWithinZeroAndOne(_ volume: Double, _ played: Float) {
        let rig = Rig()
        rig.ring(volume: volume)
        #expect(rig.engines.current?.volume == played)
    }

    // MARK: Guards

    /// The engine's input would ask for the microphone: nothing in the alarm's code may touch it.
    @Test func nothingInTheAlarmCodeTouchesTheEnginesInput() throws {
        let folder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/TimerOverlay/Alarm")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "AlarmPlayer.swift" })
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("inputNode"), "\(file.lastPathComponent) touches the engine's input")
        }
    }
}

/// Collects buffers from the tap's thread.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AlarmRenderedBuffer] = []
    func add(_ buffer: AlarmRenderedBuffer) { lock.withLock { buffers.append(buffer) } }
    var all: [AlarmRenderedBuffer] { lock.withLock { buffers } }
}

// MARK: - The live engine's pieces that need no audio hardware

@Suite("Live alarm engine")
struct LiveAlarmEngineTests {
    private static let ping = URL(filePath: "/System/Library/Sounds/Ping.aiff")

    /// Opening reads the file's header and nothing else: no engine, no output.
    @MainActor @Test func openingASoundReadsItsLengthAndRate() throws {
        let engine = try LiveAlarmEngine(sound: Self.ping)
        #expect(engine.sampleRate == 48_000)
        #expect(abs(Double(engine.soundFrameCount) / engine.sampleRate - 1.50) < 0.01)
        #expect(!engine.hasAudioEngine)
    }

    @MainActor @Test func aFileThatIsntSoundDoesntOpen() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sTools-not-a-sound-\(UUID().uuidString).wav")
        try Data("nope".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try LiveAlarmEngine(sound: url) }
        #expect(throws: (any Error).self) { try LiveAlarmEngine(sound: URL(filePath: "/nowhere/gone.wav")) }
    }

    @Test func silenceIsSilent() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try LiveAlarmEngine.silentBuffer(format: format, frames: 1_000)
        #expect(buffer.frameLength == 1_000)
        let data = try #require(buffer.floatChannelData)
        #expect((0..<2).allSatisfy { channel in (0..<1_000).allSatisfy { data[channel][$0] == 0 } })
    }

    @Test func aFadeEndsInSilenceWithoutAJump() throws {
        let file = try AVAudioFile(forReading: Self.ping)
        let original = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 960))
        file.framePosition = 2_000
        try file.read(into: original, frameCount: 960)

        let faded = try LiveAlarmEngine.fadedBuffer(from: AVAudioFile(forReading: Self.ping), start: 2_000, count: 960)

        #expect(faded.frameLength == 960)
        let before = try #require(original.floatChannelData)
        let after = try #require(faded.floatChannelData)
        for channel in 0..<Int(faded.format.channelCount) {
            #expect(abs(after[channel][0] - before[channel][0]) <= abs(before[channel][0]) * 0.001 + 1e-7, "it starts at full level")
            #expect(after[channel][959] == 0, "it ends in silence")
            for frame in 0..<960 { #expect(abs(after[channel][frame]) <= abs(before[channel][frame]) + 1e-7) }
        }
    }

    @Test func aTapBufferBecomesInterleavedSamples() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<3 {
            data[0][frame] = Float(frame) + 0.25
            data[1][frame] = -Float(frame) - 0.5
        }

        let rendered = try #require(LiveAlarmEngine.rendered(buffer, hostTime: 99))

        #expect(rendered.samples == [0.25, -0.5, 1.25, -1.5, 2.25, -2.5])
        #expect(rendered.sampleRate == 44_100)
        #expect(rendered.channelCount == 2)
        #expect(rendered.hostTime == 99)
        #expect(rendered.frameCount == 3)
    }
}
