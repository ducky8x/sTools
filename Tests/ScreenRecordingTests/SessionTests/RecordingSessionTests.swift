import CoreMedia
import CoreVideo
import Foundation
import os
import Testing
@testable import ScreenRecording

final class FakeVideoCapture: VideoCapture, @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (VideoCaptureEvent) -> Void)?>(initialState: nil)
    let failsToStart: Bool

    init(failsToStart: Bool = false) { self.failsToStart = failsToStart }

    func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        if failsToStart { throw CocoaError(.featureUnsupported) }
        handler.withLock { $0 = deliver }
    }

    func stop() async { handler.withLock { $0 = nil } }

    func push(_ event: VideoCaptureEvent) { handler.withLock { $0 }?(event) }
}

final class FakeAudioCapture: AudioCapture, @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (AudioChunk) -> Void)?>(initialState: nil)

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws { handler.withLock { $0 = deliver } }
    func stop() async { handler.withLock { $0 = nil } }

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
}
