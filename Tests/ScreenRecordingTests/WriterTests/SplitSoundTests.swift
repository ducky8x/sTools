import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

/// Where each track of a finished file sits on its timeline, in seconds from the file's start.
private struct TrackSpans {
    var video: ClosedRange<Double>
    var audio: [ClosedRange<Double>]

    static func load(_ url: URL) async throws -> TrackSpans {
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        var audio: [ClosedRange<Double>] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            audio.append(span(try await track.load(.timeRange)))
        }
        return TrackSpans(video: span(try await video.load(.timeRange)), audio: audio)
    }

    private static func span(_ range: CMTimeRange) -> ClosedRange<Double> {
        range.start.seconds...range.end.seconds
    }
}

/// A split recording keeps all of its sound (spec 5.4.2): sound is written a quarter second behind the picture
/// (`RecordingSession.audioLag`), so the sound before each cut arrives after the picture has moved on to the next part.
/// Each part keeps the sound up to its cut and the next part takes it from there: no gap, no overlap, nothing dropped.
@Suite("Split recordings' sound", .serialized)
struct SplitSoundTests {
    /// One block of sound at 30 fps.
    private static let block = 1.0 / 30

    /// The writer on its own, fed as the session feeds it: each frame, then the sound up to a quarter second before
    /// it, in blocks that don't line up with the cuts; at the end the rest of the sound up to the last frame's end.
    @Test func eachPartKeepsItsSoundUpToItsCut() async throws {
        let dir = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingWriter(configuration: WriterFixture.configuration(dir, split: 1))
        try writer.start(at: .zero)
        let frames = 105
        let lag = Int(RecordingSession.audioLag * 48_000)
        var soundEnd = 0
        func writeSound(upTo frame: Int) {
            guard frame > soundEnd else { return }
            let start = CMTime(value: CMTimeValue(soundEnd), timescale: 48_000)
            for track in 0..<2 {
                #expect(writer.append(audio: WriterFixture.makeAudio(track: track, start: start, frames: frame - soundEnd)))
            }
            soundEnd = frame
        }
        for index in 0..<frames {
            #expect(await waitUntil { writer.canAcceptFrame }, "the encoder took the last frame")
            #expect(writer.append(frame: WriterFixture.makeFrame(index: index), at: CMTime(value: CMTimeValue(index), timescale: 30)) == .written)
            writeSound(upTo: index * 1600 - lag)
        }
        writeSound(upTo: frames * 1600)
        let result = await writer.finish()

        #expect(result.droppedAudioChunks == 0)
        #expect(result.files.count == 4)
        var audioTotal = 0.0
        for file in result.files {
            let spans = try await TrackSpans.load(file)
            #expect(spans.audio.count == 2)
            for audio in spans.audio {
                #expect(abs(audio.lowerBound - spans.video.lowerBound) <= Self.block, "\(file.lastPathComponent) starts its sound with its picture")
                #expect(abs(audio.upperBound - spans.video.upperBound) <= Self.block, "\(file.lastPathComponent) keeps its sound up to its cut")
            }
            audioTotal += spans.audio[0].upperBound - spans.audio[0].lowerBound
        }
        #expect(abs(audioTotal - Double(frames) / 30) <= Self.block, "no sound lost or doubled across the cuts")
    }

    /// The whole session on fakes: a recording several times longer than its split, with Minecraft's sound coming in
    /// as it plays and the session writing it a quarter second behind the picture.
    @Test func aLongSplitRecordingKeepsEachPartsSound() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = PixelSize(width: 320, height: 180)
        let base = FakeVideoCapture(), game = FakeAudioCapture()
        let rig = CaptureRig(video: [.base: base], audio: [.minecraft: game], minimizedShowsNothing: false)
        await rig.start()
        let clock = ManualClock(100)
        let driver = ManualTickDriver()
        var options = RecordingOptions()
        options.frameRate = .fps30
        var configuration = RecordingSession.Configuration(
            layout: RecordingLayout(), options: options, canvas: canvas, baseName: "long", directory: directory)
        configuration.splitIntervalSeconds = 2
        let session = try RecordingSession(configuration: configuration, rig: rig, clock: clock, driver: driver)
        let picture = { (seconds: Double) in
            VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: Int(seconds * 30), size: canvas), hostTime: .seconds(seconds))
        }
        base.push(.frame(picture(100)))
        try session.start()
        let ticks = 7 * 30
        for i in 0..<ticks {
            let now = 100 + Double(i) / 30
            game.push(frames: 1600, at: now, frequency: 440)
            base.push(.frame(picture(now)))
            clock.set(now + 0.001)
            driver.fire()
            try await Task.sleep(for: .milliseconds(4))
        }
        let result = await session.stop()
        await rig.stop()

        #expect(result.stopReason == .finished)
        #expect(result.droppedAudioChunks == 0)
        #expect(result.files.map(\.lastPathComponent) == ["long.mov", "long part 2.mov", "long part 3.mov", "long part 4.mov"])
        for file in result.files {
            let spans = try await TrackSpans.load(file)
            #expect(spans.audio.count == 2, "the mix and Minecraft")
            for audio in spans.audio {
                #expect(abs(audio.lowerBound - spans.video.lowerBound) <= Self.block, "\(file.lastPathComponent) starts its sound with its picture")
                #expect(abs(audio.upperBound - spans.video.upperBound) <= Self.block, "\(file.lastPathComponent) keeps its sound up to its cut")
            }
        }
    }
}
