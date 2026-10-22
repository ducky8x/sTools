import CoreMedia
import CoreVideo
import Foundation
import os
import STPlatform
import Testing
@testable import ScreenRecording

/// The order fake sources stopped in, by the names the test gave them.
final class StopLog: @unchecked Sendable {
    private let names = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ name: String) { names.withLock { $0.append(name) } }
    var all: [String] { names.withLock { $0 } }
}

/// Waits `duration` whether or not the task is canceled, as ScreenCaptureKit, AVFoundation and Core Audio finish
/// starting a source even when the task that asked has been canceled since.
func uncancellableWait(_ duration: Duration) async {
    await Task.detached { try? await Task.sleep(for: duration) }.value
}

final class FakeVideoCapture: VideoCapture, @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (VideoCaptureEvent) -> Void)?>(initialState: nil)
    let failsToStart: Bool
    private let name: String
    private let stops: StopLog?
    /// How long starting takes, as a real stream's or camera's start can.
    private let startTakes: Duration?
    /// Delivered as it starts, as ScreenCaptureKit sends a stream's first frame.
    private let firstFrame: VideoFrame?
    /// How long stopping takes, as a real stream's or camera's stop can.
    private let stopTakes: Duration?

    init(failsToStart: Bool = false, name: String = "video", stops: StopLog? = nil, startTakes: Duration? = nil,
         firstFrame: VideoFrame? = nil, stopTakes: Duration? = nil) {
        self.failsToStart = failsToStart
        self.name = name
        self.stops = stops
        self.startTakes = startTakes
        self.firstFrame = firstFrame
        self.stopTakes = stopTakes
    }

    func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        if let startTakes { await uncancellableWait(startTakes) }
        if failsToStart { throw CocoaError(.featureUnsupported) }
        handler.withLock { $0 = deliver }
        if let firstFrame { deliver(.frame(firstFrame)) }
    }

    func stop() async {
        if let stopTakes { try? await Task.sleep(for: stopTakes) }
        let wasRunning = handler.withLock { handler in
            defer { handler = nil }
            return handler != nil
        }
        if wasRunning { stops?.append(name) }
    }

    /// Started and not stopped since: a real camera's light, or macOS's recording indicator for a screen, would be on.
    var isRunning: Bool { handler.withLock { $0 != nil } }

    func push(_ event: VideoCaptureEvent) { handler.withLock { $0 }?(event) }
}

final class FakeAudioCapture: AudioCapture, @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (AudioChunk) -> Void)?>(initialState: nil)
    private let name: String
    private let stops: StopLog?
    private let startTakes: Duration?
    private let stopTakes: Duration?

    init(name: String = "audio", stops: StopLog? = nil, startTakes: Duration? = nil, stopTakes: Duration? = nil) {
        self.name = name
        self.stops = stops
        self.startTakes = startTakes
        self.stopTakes = stopTakes
    }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws {
        if let startTakes { await uncancellableWait(startTakes) }
        handler.withLock { $0 = deliver }
    }

    func stop() async {
        if let stopTakes { try? await Task.sleep(for: stopTakes) }
        let wasRunning = handler.withLock { handler in
            defer { handler = nil }
            return handler != nil
        }
        if wasRunning { stops?.append(name) }
    }

    /// Started and not stopped since: macOS's indicator for recording sound would be on.
    var isRunning: Bool { handler.withLock { $0 != nil } }

    /// `frames` of a quiet tone at 48 kHz stereo, stamped `hostSeconds`.
    func push(frames: Int, at hostSeconds: Double, frequency: Double) {
        let start = Int(hostSeconds * 48_000)
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(sin(Double(start + i) * 2 * .pi * frequency / 48_000) * 0.2)
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        handler.withLock { $0 }?(AudioChunk(samples: samples, sampleRate: 48_000, channelCount: 2, hostTime: .seconds(hostSeconds)))
    }
}

private func solidFrame(_ size: PixelSize, at seconds: Double) -> VideoFrame {
    VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: Int(seconds * 30), size: size), hostTime: .seconds(seconds))
}

@Suite("Recording session", .serialized)
struct RecordingSessionTests {
    @Test func aRecordingHasEveryFrameAndANamedTrackPerSource() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = PixelSize(width: 320, height: 180)
        let camera = VideoSource(kind: .camera(CameraReference(uniqueID: "cam", name: "Camera")), frame: PixelRect(x: 200, y: 100, width: 100, height: 60), on: canvas)
        let mic = AudioSource(kind: .microphone(uniqueID: "mic"), name: "Microphone", volume: 0.5)
        var layout = RecordingLayout()
        layout.add(camera)
        layout.add(mic)

        let base = FakeVideoCapture(), cam = FakeVideoCapture()
        let game = FakeAudioCapture(), voice = FakeAudioCapture()
        let rig = CaptureRig(video: [.base: base, .source(camera.id): cam], audio: [.minecraft: game, .source(mic.id): voice], minimizedShowsNothing: false)
        await rig.start()

        let clock = ManualClock(100)
        let driver = ManualTickDriver()
        var options = RecordingOptions()
        options.frameRate = .fps30
        let session = try RecordingSession(
            configuration: .init(layout: layout, options: options, canvas: canvas, baseName: "take", directory: directory),
            rig: rig, clock: clock, driver: driver)
        #expect(session.tracks.map(\.title) == ["Minecraft", "Microphone"])

        base.push(.frame(solidFrame(canvas, at: 100)))
        cam.push(.frame(solidFrame(PixelSize(width: 64, height: 36), at: 100)))
        try session.start()
        for i in 0..<60 {
            let now = 100 + Double(i) / 30
            game.push(frames: 1600, at: now, frequency: 440)
            voice.push(frames: 1600, at: now, frequency: 660)
            if i % 3 == 0 { base.push(.frame(solidFrame(canvas, at: now))) }
            clock.set(now + 0.001)
            driver.fire()
            try await Task.sleep(for: .milliseconds(4))
        }
        for i in 60..<70 {
            let now = 100 + Double(i) / 30
            game.push(frames: 1600, at: now, frequency: 440)
            voice.push(frames: 1600, at: now, frequency: 660)
        }
        let result = await session.stop()
        await rig.stop()

        #expect(result.stopReason == .finished)
        #expect(result.framesWritten + session.droppedFrames == 60)
        #expect(result.framesWritten > 40)
        let info = try await MovieInfo.load(try #require(result.files.first))
        #expect(info.videoSampleCount == result.framesWritten)
        #expect(info.audioTracks.map(\.title) == ["Mix", "Minecraft", "Microphone"])
        // AAC tracks count 1024-frame packets, not samples.
        let packets = info.audioTracks.map(\.sampleCount)
        #expect(packets.allSatisfy { abs($0 - packets[0]) <= 2 })
        #expect(abs(Double(packets[0] * 1024) / 48_000 - 2.0) < 0.1)
    }

    /// Timer Overlay's alarm on its own track (spec 5.4.1): synthetic buffers through an in-process feed, stamped
    /// in host ticks as the alarm's tap stamps them.
    private func recordWithAlarmFeed(wantsRecording: Bool, in directory: URL) async throws -> (RecordingSession, MovieInfo) {
        let canvas = PixelSize(width: 320, height: 180)
        let feed = InProcessAudio().feed(named: "Timer alarm")
        let base = FakeVideoCapture(), game = FakeAudioCapture()
        let rig = CaptureRig(
            video: [.base: base], audio: [.minecraft: game, .feed(feed.name): FeedCapture(feed: feed)], minimizedShowsNothing: false)
        await rig.start()
        let clock = ManualClock(100)
        let driver = ManualTickDriver()
        var options = RecordingOptions()
        options.frameRate = .fps30
        let session = try RecordingSession(
            configuration: .init(layout: RecordingLayout(), options: options, canvas: canvas, baseName: "alarm",
                                 directory: directory, feeds: wantsRecording ? [feed.name] : []),
            rig: rig, clock: clock, driver: driver)
        base.push(.frame(solidFrame(canvas, at: 100)))
        try session.start()
        func publishAlarm(at now: Double) {
            let start = Int(now * 48_000)
            let samples = (0..<1600).flatMap { i -> [Float] in
                let v = Float(sin(Double(start + i) * 2 * .pi * 880 / 48_000) * 0.3)
                return [v, v]
            }
            feed.publish(InProcessAudioBuffer(samples: samples, sampleRate: 48_000, channelCount: 2, hostTime: hostTicks(now)))
        }
        for i in 0..<30 {
            let now = 100 + Double(i) / 30
            game.push(frames: 1600, at: now, frequency: 440)
            publishAlarm(at: now)
            if i % 3 == 0 { base.push(.frame(solidFrame(canvas, at: now))) }
            clock.set(now + 0.001)
            driver.fire()
            try await Task.sleep(for: .milliseconds(4))
        }
        for i in 30..<40 {
            let now = 100 + Double(i) / 30
            game.push(frames: 1600, at: now, frequency: 440)
            publishAlarm(at: now)
        }
        let result = await session.stop()
        await rig.stop()
        #expect(!feed.hasListeners)
        return (session, try await MovieInfo.load(try #require(result.files.first)))
    }

    @Test func aFeedThatWantsRecordingIsANamedTrackAfterTheSources() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, info) = try await recordWithAlarmFeed(wantsRecording: true, in: directory)
        #expect(session.tracks.map(\.title) == ["Minecraft", "Timer alarm"])
        #expect(session.tracks.last?.id == .feed("Timer alarm"))
        #expect(session.tracks.last?.volume == 1)
        #expect(info.audioTracks.map(\.title) == ["Mix", "Minecraft", "Timer alarm"])
        let packets = info.audioTracks.map(\.sampleCount)
        #expect(packets.allSatisfy { abs($0 - packets[0]) <= 2 })
        #expect(abs(Double(packets[0] * 1024) / 48_000 - 1.0) < 0.1)
    }

    @Test func aFeedThatDoesNotWantRecordingGetsNoTrack() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, info) = try await recordWithAlarmFeed(wantsRecording: false, in: directory)
        #expect(session.tracks.map(\.title) == ["Minecraft"])
        #expect(info.audioTracks.map(\.title) == ["Mix", "Minecraft"])
    }

    @Test func aSilentLayoutWritesNoAudioTracks() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = FakeVideoCapture()
        let rig = CaptureRig(video: [.base: base], audio: [:], minimizedShowsNothing: false)
        await rig.start()
        let clock = ManualClock(5)
        let driver = ManualTickDriver()
        var options = RecordingOptions()
        options.frameRate = .fps30
        let session = try RecordingSession(
            configuration: .init(layout: RecordingLayout(), options: options, canvas: PixelSize(width: 320, height: 180), baseName: "quiet", directory: directory),
            rig: rig, clock: clock, driver: driver)
        base.push(.frame(solidFrame(PixelSize(width: 320, height: 180), at: 5)))
        try session.start()
        for i in 0..<10 {
            clock.set(5 + Double(i) / 30 + 0.001)
            driver.fire()
            try await Task.sleep(for: .milliseconds(4))
        }
        let result = await session.stop()
        await rig.stop()
        let info = try await MovieInfo.load(try #require(result.files.first))
        #expect(info.audioTracks.isEmpty)
        #expect(info.videoSampleCount > 5)
    }
}

@Suite("Capture rig", .serialized)
struct CaptureRigTests {
    @Test func endedAndFailingSourcesAreReportedAndEmptied() async throws {
        let id = UUID()
        let window = FakeVideoCapture(), broken = FakeVideoCapture(failsToStart: true)
        let rig = CaptureRig(video: [.source(id): window, .base: broken], audio: [:], minimizedShowsNothing: false)
        await rig.start()
        window.push(.frame(solidFrame(PixelSize(width: 8, height: 8), at: 1)))
        #expect(rig.hub.snapshot().frames[.source(id)] != nil)
        window.push(.ended("The window closed."))
        #expect(rig.hub.snapshot().frames[.source(id)] == nil)
        await rig.stop()
        var events: [RigEvent] = []
        for await event in rig.events { events.append(event) }
        #expect(events.contains(.started(.source(id))))
        #expect(events.contains { if case .failedToStart(.base, _) = $0 { true } else { false } })
        #expect(events.contains(.ended(.source(id), "The window closed.")))
    }

    @Test func aMinimizedWindowCanShowNothing() async throws {
        let id = UUID()
        let window = FakeVideoCapture()
        let rig = CaptureRig(video: [.source(id): window], audio: [:], minimizedShowsNothing: true)
        await rig.start()
        window.push(.frame(solidFrame(PixelSize(width: 8, height: 8), at: 1)))
        window.push(.minimized(true))
        #expect(rig.hub.snapshot().frames[.source(id)] == nil)
        window.push(.minimized(false))
        #expect(rig.hub.snapshot().frames[.source(id)] != nil)
        await rig.stop()
    }

    /// The sources of a recording start together (spec 5.4.4): switching the tool on with its key waits for the
    /// slowest source, not for each in turn. Three pictures and two sounds that each take 200 ms to start are all up in
    /// about 200 ms; one after another they would take a second.
    @Test func everySourceStartsAtOnce() async {
        let take = Duration.milliseconds(200)
        let video: [SourceKey: any VideoCapture] = [
            .base: FakeVideoCapture(startTakes: take),
            .source(UUID()): FakeVideoCapture(startTakes: take),
            .source(UUID()): FakeVideoCapture(startTakes: take),
        ]
        let audio: [AudioTrackID: any AudioCapture] = [
            .minecraft: FakeAudioCapture(startTakes: take),
            .source(UUID()): FakeAudioCapture(startTakes: take),
        ]
        let rig = CaptureRig(video: video, audio: audio, minimizedShowsNothing: false)
        let began = ContinuousClock.now
        await rig.start()
        let took = ContinuousClock.now - began
        #expect(took >= take)
        #expect(took < .milliseconds(800))
        #expect(video.values.allSatisfy { ($0 as? FakeVideoCapture)?.isRunning == true })
        #expect(audio.values.allSatisfy { ($0 as? FakeAudioCapture)?.isRunning == true })
        await rig.stop()
    }

    /// The stop ends every picture at once (spec 5.4.4: "stopping recording turns off the tool"): a camera that's slow
    /// to stop doesn't keep the screen's recording indicator on behind it. Three pictures that each take 200 ms to stop
    /// are all off in about 200 ms; one after another they would take 600 ms. The sound keeps running for the
    /// recording's last samples.
    @Test func everyPictureStopsAtOnce() async {
        let take = Duration.milliseconds(200)
        let pictures = [FakeVideoCapture(stopTakes: take), FakeVideoCapture(stopTakes: take), FakeVideoCapture(stopTakes: take)]
        let sound = FakeAudioCapture()
        let rig = CaptureRig(
            video: [.base: pictures[0], .source(UUID()): pictures[1], .source(UUID()): pictures[2]],
            audio: [.minecraft: sound], minimizedShowsNothing: false)
        await rig.start()
        let began = ContinuousClock.now
        await rig.stopVideo()
        let took = ContinuousClock.now - began
        #expect(took >= take)
        #expect(took < .milliseconds(450))
        #expect(pictures.allSatisfy { !$0.isRunning })
        #expect(sound.isRunning)
        await rig.stop()
        #expect(!sound.isRunning)
    }

    /// The full stop ends the sounds at once too, once the pictures are off.
    @Test func everySoundStopsAtOnce() async {
        let take = Duration.milliseconds(200)
        let sounds = [FakeAudioCapture(stopTakes: take), FakeAudioCapture(stopTakes: take), FakeAudioCapture(stopTakes: take)]
        let rig = CaptureRig(
            video: [.base: FakeVideoCapture()],
            audio: [.minecraft: sounds[0], .source(UUID()): sounds[1], .source(UUID()): sounds[2]], minimizedShowsNothing: false)
        await rig.start()
        let began = ContinuousClock.now
        await rig.stop()
        let took = ContinuousClock.now - began
        #expect(took >= take)
        #expect(took < .milliseconds(450))
        #expect(sounds.allSatisfy { !$0.isRunning })
    }

    /// A stop that comes while the sources start (a second press of the key, the tool switched off) leaves nothing
    /// running, even though each source finishes starting after the stop, as ScreenCaptureKit's stream, a camera and
    /// a process tap can. The fakes ignore a stop that comes before their start finished, as a source without its own
    /// guard would.
    @Test func aStopWhileTheSourcesStartLeavesNothingRunning() async {
        let take = Duration.milliseconds(200)
        let pictures = [FakeVideoCapture(startTakes: take, firstFrame: solidFrame(PixelSize(width: 8, height: 8), at: 1)),
                        FakeVideoCapture(startTakes: take)]
        let sounds = [FakeAudioCapture(startTakes: take), FakeAudioCapture(startTakes: take)]
        let rig = CaptureRig(
            video: [.base: pictures[0], .source(UUID()): pictures[1]],
            audio: [.minecraft: sounds[0], .source(UUID()): sounds[1]], minimizedShowsNothing: false)
        let starting = Task { await rig.start() }
        try? await Task.sleep(for: .milliseconds(50))
        await rig.stop()
        await starting.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pictures.allSatisfy { !$0.isRunning })
        #expect(sounds.allSatisfy { !$0.isRunning })
        #expect(!rig.hasStarted(.base))
        #expect(rig.hub.snapshot().frames.isEmpty)
    }

    /// A rig that was stopped before it started starts nothing.
    @Test func aStoppedRigStartsNothing() async {
        let picture = FakeVideoCapture(), sound = FakeAudioCapture()
        let rig = CaptureRig(video: [.base: picture], audio: [.minecraft: sound], minimizedShowsNothing: false)
        await rig.stop()
        await rig.start()
        #expect(!picture.isRunning)
        #expect(!sound.isRunning)
        #expect(!rig.hasStarted(.base))
    }

    /// Pictures stopped while they start (a recording stopped at once) stay stopped; the sound runs on until the full
    /// stop.
    @Test func picturesStoppedWhileTheyStartStayStopped() async {
        let take = Duration.milliseconds(200)
        let picture = FakeVideoCapture(startTakes: take), sound = FakeAudioCapture()
        let rig = CaptureRig(video: [.base: picture], audio: [.minecraft: sound], minimizedShowsNothing: false)
        let starting = Task { await rig.start() }
        try? await Task.sleep(for: .milliseconds(50))
        await rig.stopVideo()
        await starting.value
        #expect(!picture.isRunning)
        #expect(sound.isRunning)
        await rig.stop()
        #expect(!sound.isRunning)
    }

    /// It knows which pictures are running: a start waits for Minecraft's first frame only when its capture started.
    @Test func itKnowsWhichPicturesStarted() async {
        let camera = SourceKey.source(UUID())
        let rig = CaptureRig(
            video: [.base: FakeVideoCapture(failsToStart: true), camera: FakeVideoCapture()], audio: [:],
            minimizedShowsNothing: false)
        #expect(!rig.hasStarted(.base) && !rig.hasStarted(camera))
        await rig.start()
        #expect(!rig.hasStarted(.base))
        #expect(rig.hasStarted(camera))
        await rig.stop()
    }
}
