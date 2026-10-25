import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ScreenRecording

/// The presentation times of a movie's video samples, in seconds, in file order.
func videoSampleTimes(of url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    #expect(reader.startReading())
    var times: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
    }
    return times
}

/// A tick whose sources brought nothing new writes the last picture again instead of drawing it again, and Minecraft
/// alone at the output size is handed on without drawing; the file is the same either way: a frame for every tick,
/// each at its own time.
@Suite("Recording frame reuse and pass-through", .serialized)
struct RecordingPictureTests {
    private let canvas = PixelSize(width: 320, height: 180)

    private func frame(_ index: Int, at seconds: Double, size: PixelSize? = nil) -> VideoFrame {
        VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: index, size: size ?? canvas), hostTime: .seconds(seconds))
    }

    /// Records `ticks` ticks at 30 fps from host time 10; `beforeTick` runs before each, with its index.
    private func record(
        layout: RecordingLayout = RecordingLayout(), video: [SourceKey: FakeVideoCapture], minimizedShowsNothing: Bool = false,
        ticks: Int, in directory: URL, beforeTick: (Int) -> Void
    ) async throws -> (RecordingSession, WriterResult) {
        let rig = CaptureRig(video: video, audio: [:], minimizedShowsNothing: minimizedShowsNothing)
        await rig.start()
        let clock = ManualClock(10)
        let driver = ManualTickDriver()
        var options = RecordingOptions()
        options.frameRate = .fps30
        let session = try RecordingSession(
            configuration: .init(layout: layout, options: options, canvas: canvas, baseName: "reuse", directory: directory),
            rig: rig, clock: clock, driver: driver)
        try session.start()
        for i in 0..<ticks {
            beforeTick(i)
            clock.set(10 + Double(i) / 30 + 0.001)
            driver.fire()
            try await Task.sleep(for: .milliseconds(4))
        }
        let result = await session.stop()
        await rig.stop()
        return (session, result)
    }

    @Test func aStillSceneWritesAFrameEveryTickAtItsTimeAndDrawsItOnce() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = FakeVideoCapture()
        let (session, result) = try await record(video: [.base: base], ticks: 20, in: directory) { i in
            if i == 0 { base.push(.frame(frame(0, at: 10))) }
        }
        #expect(result.framesWritten + session.droppedFrames == 20)
        #expect(result.framesWritten > 10)
        #expect(session.picturesDrawn == 1)
        #expect(session.picturesReused == result.framesWritten - 1)
        let times = try await videoSampleTimes(of: try #require(result.files.first))
        #expect(times.count == result.framesWritten)
        // Every frame keeps its own slot's time: reused pictures are stamped like drawn ones.
        #expect(times == times.sorted())
        #expect(Set(times).count == times.count)
        for time in times { #expect(abs(time * 30 - (time * 30).rounded()) < 0.001) }
        if session.droppedFrames == 0 { #expect(times == (0..<20).map { Double($0) / 30 }) }
    }

    @Test func noSourceAtAllDrawsTheBlackCanvasOnce() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, result) = try await record(video: [:], ticks: 12, in: directory) { _ in }
        #expect(result.framesWritten + session.droppedFrames == 12)
        #expect(session.picturesDrawn == 1)
        #expect(session.picturesReused == result.framesWritten - 1)
    }

    @Test func eachNewFrameIsDrawnAndTheTicksBetweenReuseIt() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = FakeVideoCapture()
        let (session, result) = try await record(video: [.base: base], ticks: 21, in: directory) { i in
            if i % 3 == 0 { base.push(.frame(frame(i, at: 10 + Double(i) / 30))) }
        }
        #expect(session.picturesDrawn + session.picturesReused == result.framesWritten)
        #expect(session.picturesDrawn <= 7)
        if session.droppedFrames == 0 {
            #expect(session.picturesDrawn == 7)
            #expect(session.picturesReused == 14)
        }
    }

    @Test func aSourceThatGoesAwayOrHidesIsDrawnAgain() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cameraID = UUID()
        var layout = RecordingLayout()
        layout.add(VideoSource(
            id: cameraID, kind: .camera(CameraReference(uniqueID: "cam", name: "Camera")),
            frame: PixelRect(x: 200, y: 100, width: 100, height: 60), on: canvas))
        let base = FakeVideoCapture(), camera = FakeVideoCapture()
        let (session, result) = try await record(
            layout: layout, video: [.base: base, .source(cameraID): camera], minimizedShowsNothing: true, ticks: 12,
            in: directory
        ) { i in
            switch i {
            case 0:
                base.push(.frame(frame(0, at: 10)))
                camera.push(.frame(frame(1, at: 10, size: PixelSize(width: 64, height: 36))))
            case 3: camera.push(.minimized(true))
            case 6: camera.push(.minimized(false))
            case 9: camera.push(.ended("unplugged"))
            default: break
            }
        }
        // Drawn at the start, as the window hides ("Show nothing"), as it shows again, and as it ends.
        if session.droppedFrames == 0 {
            #expect(session.picturesDrawn == 4)
            #expect(session.picturesReused == 8)
        }
        #expect(session.picturesDrawn + session.picturesReused == result.framesWritten)
    }

    // MARK: Pass-through

    @Test func minecraftAloneAtTheCanvasSizeIsHandedOnWithoutDrawing() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = FakeVideoCapture()
        let (session, result) = try await record(video: [.base: base], ticks: 12, in: directory) { i in
            if i % 2 == 0 { base.push(.frame(frame(i, at: 10 + Double(i) / 30))) }
        }
        #expect(session.picturesDrawn > 0)
        #expect(session.picturesPassedThrough == session.picturesDrawn)
        let times = try await videoSampleTimes(of: try #require(result.files.first))
        #expect(times.count == result.framesWritten)
        if session.droppedFrames == 0 { #expect(times == (0..<12).map { Double($0) / 30 }) }
    }

    @Test func aPictureThatMustBeDrawnIsDrawnAndTheFileTakesBothKinds() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = FakeVideoCapture()
        // A window resized smaller fills only part of its buffer for a while: those frames are drawn, the rest handed on.
        let (session, result) = try await record(video: [.base: base], ticks: 12, in: directory) { i in
            let resized = (4..<8).contains(i)
            base.push(.frame(VideoFrame(
                pixelBuffer: WriterFixture.makeFrame(index: i, size: canvas),
                contentRect: resized ? PixelRect(x: 0, y: 0, width: 160, height: 90) : nil,
                hostTime: .seconds(10 + Double(i) / 30))))
        }
        #expect(session.picturesPassedThrough > 0)
        #expect(session.picturesPassedThrough < session.picturesDrawn)
        let info = try await MovieInfo.load(try #require(result.files.first))
        #expect(info.videoSampleCount == result.framesWritten)
        if session.droppedFrames == 0 { #expect(session.picturesDrawn - session.picturesPassedThrough == 4) }
    }

    @Test func aSmallerOutputIsAlwaysDrawn() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = FakeVideoCapture()
        // 1080p of a canvas taller than 1080 pixels is scaled down, so nothing is handed on as it is.
        let tall = PixelSize(width: 2560, height: 1440)
        let rig = CaptureRig(video: [.base: base], audio: [:], minimizedShowsNothing: false)
        await rig.start()
        let clock = ManualClock(10)
        let driver = ManualTickDriver()
        var options = RecordingOptions()
        options.frameRate = .fps30
        options.outputSize = .p1080
        let session = try RecordingSession(
            configuration: .init(layout: RecordingLayout(), options: options, canvas: tall, baseName: "small", directory: directory),
            rig: rig, clock: clock, driver: driver)
        try session.start()
        for i in 0..<6 {
            base.push(.frame(VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: i, size: tall), hostTime: .seconds(10 + Double(i) / 30))))
            clock.set(10 + Double(i) / 30 + 0.001)
            driver.fire()
            try await Task.sleep(for: .milliseconds(4))
        }
        _ = await session.stop()
        await rig.stop()
        #expect(session.picturesDrawn > 0)
        #expect(session.picturesPassedThrough == 0)
    }
}
