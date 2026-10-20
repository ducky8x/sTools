import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

@Suite("RecordingWriter")
struct RecordingWriterTests {
    @Test func writesH264MovieWithNamedAudioTracks() async throws {
        let dir = try WriterFixture.makeDirectory()
        let writer = RecordingWriter(configuration: WriterFixture.configuration(dir, audio: ["Mix", "Game", "Mic"]))
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 60, audioTracks: 3)
        let result = await writer.finish()

        #expect(result.files == [dir.appendingPathComponent("take.mov")])
        #expect(result.framesWritten == 60)
        #expect(result.droppedFrames == 0)
        #expect(result.stopReason == .finished)
        let info = try await MovieInfo.load(result.files[0])
        #expect(abs(info.duration - 2.0) < 0.2)
        #expect(abs(info.nominalFrameRate - 30) < 1)
        #expect(info.videoCodec == "avc1")
        #expect(info.videoSampleCount == 60)
        #expect(info.audioTracks.map(\.title) == ["Mix", "Game", "Mic"])
        #expect(info.audioTracks.allSatisfy { $0.sampleCount > 0 })
        let size = try FileManager.default.attributesOfItem(atPath: result.files[0].path)[.size] as? Int
        #expect((size ?? 0) > 10_000)
    }

    @Test func writesHEVCWithManualQuality() async throws {
        let dir = try WriterFixture.makeDirectory()
        let config = WriterFixture.configuration(dir, audio: [], codec: .hevc, quality: .manual(0.6))
        let writer = RecordingWriter(configuration: config)
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 30, audioTracks: 0)
        let result = await writer.finish()
        let info = try await MovieInfo.load(result.files[0])
        #expect(info.videoCodec == "hvc1")
        #expect(info.videoSampleCount == 30)
        #expect(info.audioTracks.isEmpty)
    }

    @Test func automaticBitRateScalesWithSizeFrameRateAndCodec() {
        let hd = PixelSize(width: 1920, height: 1080)
        let h264 = RecordingWriter.automaticBitRate(canvas: hd, frameRate: 60, codec: .h264)
        let hevc = RecordingWriter.automaticBitRate(canvas: hd, frameRate: 60, codec: .hevc)
        #expect(h264 > hevc)
        #expect(RecordingWriter.automaticBitRate(canvas: hd, frameRate: 30, codec: .h264) < h264)
        #expect(RecordingWriter.automaticBitRate(canvas: PixelSize(width: 2, height: 2), frameRate: 1, codec: .h264) == 500_000)
    }

    @Test func fileGrowsAndSurvivesAbandonment() async throws {
        let dir = try WriterFixture.makeDirectory()
        let writer = RecordingWriter(configuration: WriterFixture.configuration(dir))
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 120)
        var grown = false
        for _ in 0..<200 where !grown {
            grown = writer.currentFileSize > 20_000
            if !grown { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(grown)

        // Copy the file while the writer is still open and never finished, as a crash would leave it.
        let url = try #require(writer.currentFileURL)
        var recoveredDuration = 0.0
        for attempt in 0..<40 where recoveredDuration <= 0 {
            let copy = dir.appendingPathComponent("crashed-\(attempt).mov")
            try FileManager.default.copyItem(at: url, to: copy)
            recoveredDuration = (try? await AVURLAsset(url: copy).load(.duration).seconds) ?? 0
            if recoveredDuration <= 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(recoveredDuration > 0.5)
        _ = await writer.finish()
    }

    @Test func stalledInputDropsAndCountsFrames() async throws {
        let dir = try WriterFixture.makeDirectory()
        let stalled = Flag(false)
        let writer = RecordingWriter(
            configuration: WriterFixture.configuration(dir, audio: []),
            freeSpace: FakeFreeSpace(.max),
            readinessOverride: { !stalled.value })
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 10, audioTracks: 0)
        stalled.value = true
        var dispositions: [FrameDisposition] = []
        for index in 10..<25 {
            dispositions.append(writer.append(frame: WriterFixture.makeFrame(index: index), at: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        #expect(dispositions.allSatisfy { $0 == .dropped })
        stalled.value = false
        await WriterFixture.feed(writer, frames: 10, from: 25, audioTracks: 0)
        let result = await writer.finish()

        #expect(result.droppedFrames == 15)
        #expect(result.framesWritten == 20)
        let info = try await MovieInfo.load(result.files[0])
        #expect(info.videoSampleCount == 20)
    }

    @Test func rejectsFramesOutOfOrderOrWrongSize() async throws {
        let dir = try WriterFixture.makeDirectory()
        let writer = RecordingWriter(configuration: WriterFixture.configuration(dir, audio: []))
        #expect(writer.append(frame: WriterFixture.makeFrame(index: 0), at: .zero) == .stopped)
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 3, audioTracks: 0)
        let late = writer.append(frame: WriterFixture.makeFrame(index: 1), at: CMTime(value: 1, timescale: 30))
        let wrongSize = writer.append(
            frame: WriterFixture.makeFrame(index: 5, size: PixelSize(width: 160, height: 90)),
            at: CMTime(value: 5, timescale: 30))
        #expect(late == .dropped)
        #expect(wrongSize == .dropped)
        let result = await writer.finish()
        #expect(result.droppedFrames == 2)
        #expect(throws: RecordingWriterError.alreadyStarted) { try writer.start(at: .zero) }
    }

    @Test func splitsIntoNumberedFilesWithoutLosingFrames() async throws {
        let dir = try WriterFixture.makeDirectory()
        let writer = RecordingWriter(configuration: WriterFixture.configuration(dir, split: 1))
        try writer.start(at: CMTime(value: 5000, timescale: 1))
        await WriterFixture.feed(writer, frames: 105, origin: CMTime(value: 5000, timescale: 1))
        let result = await writer.finish()

        #expect(result.files.map(\.lastPathComponent) == ["take.mov", "take part 2.mov", "take part 3.mov", "take part 4.mov"])
        #expect(result.framesWritten == 105)
        var total = 0
        for file in result.files {
            let info = try await MovieInfo.load(file)
            total += info.videoSampleCount
            #expect(info.duration >= 0.45)
            #expect(info.audioTracks.map(\.title) == ["Mix", "Game"])
        }
        #expect(total == 105)
        let events = await collect(writer.events)
        let started = events.compactMap { event -> Int? in
            if case .segmentStarted(let index, _) = event { index } else { nil }
        }
        #expect(started == [1, 2, 3, 4])
    }

    @Test func warnsThenStopsOnLowDisk() async throws {
        let dir = try WriterFixture.makeDirectory()
        let space = FakeFreeSpace(100 * 1_073_741_824)
        let writer = RecordingWriter(configuration: WriterFixture.configuration(dir, audio: []), freeSpace: space)
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 30, audioTracks: 0)
        space.free = 5 * 1_073_741_824
        await WriterFixture.feed(writer, frames: 30, from: 30, audioTracks: 0)
        space.free = 100 * 1_048_576
        await WriterFixture.feed(writer, frames: 30, from: 60, audioTracks: 0)
        let after = writer.append(frame: WriterFixture.makeFrame(index: 99), at: CMTime(value: 99, timescale: 30))
        let result = await writer.finish()

        #expect(after == .stopped)
        #expect(result.stopReason == .lowDisk)
        #expect(result.framesWritten == 60)
        let info = try await MovieInfo.load(result.files[0])
        #expect(info.videoSampleCount == 60)
        let events = await collect(writer.events)
        #expect(events.contains(.lowDiskWarning(freeBytes: 5 * 1_073_741_824)))
        #expect(events.contains(.stoppedForLowDisk(freeBytes: 100 * 1_048_576)))
        #expect(events.filter { if case .lowDiskWarning = $0 { true } else { false } }.count == 1)
    }

    @Test func buildsConfigurationFromOptions() {
        var options = RecordingOptions()
        options.frameRate = .fps30
        options.split = .sixtyMinutes
        options.lowDiskWarningGB = 20
        options.codec = .hevc
        let config = WriterConfiguration(
            options: options, baseName: "x", canvas: PixelSize(width: 1920, height: 1080),
            audioTrackNames: ["Mix"], directory: URL(fileURLWithPath: "/tmp/x"))
        #expect(config.frameRate == 30)
        #expect(config.splitIntervalSeconds == 3600)
        #expect(config.lowDiskWarningBytes == 20 * 1_073_741_824)
        #expect(config.codec == .hevc)
    }
}
