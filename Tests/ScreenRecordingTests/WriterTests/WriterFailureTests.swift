import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

/// A writer that can't go on (the next part can't open at a split because the folder went, the drive was unplugged or
/// the disk filled, or the part being written fails) stops cleanly with a reason and keeps every part already written.
/// Each part is finished exactly once: AVFoundation ends sTools with an exception when a file is ended twice.
@Suite("RecordingWriter's failures", .serialized)
struct WriterFailureTests {
    private static let fps = 30

    private static func time(_ frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
    }

    /// Feeds frames `range` as the session does: each frame, then (with sound) the sound up to `lagFrames` frames
    /// behind it, so a part split off still waits for its sound when the next part begins. Returns the first frame
    /// the writer refused because it had stopped, nil when it took them all.
    private static func feed(
        _ writer: RecordingWriter, frames range: Range<Int>, sound: Bool, lagFrames: Int = 8,
        before: (Int) -> Void = { _ in }
    ) async -> Int? {
        for index in range {
            before(index)
            await WriterFixture.waitForEncoder(writer)
            if writer.append(frame: WriterFixture.makeFrame(index: index), at: time(index)) == .stopped { return index }
            let soundFrame = index - lagFrames
            if sound, soundFrame >= 0 {
                for track in 0..<2 {
                    writer.append(audio: WriterFixture.makeAudio(track: track, start: time(soundFrame), frames: 48_000 / fps))
                }
            }
        }
        return nil
    }

    private static func configuration(_ directory: URL, sound: Bool, split: TimeInterval? = 1) -> WriterConfiguration {
        WriterFixture.configuration(directory, audio: sound ? ["Mix", "Game"] : [], split: split)
    }

    private static func finishedIndices(_ events: [WriterEvent]) -> [Int] {
        events.compactMap { if case .segmentFinished(let index, _) = $0 { index } else { nil } }
    }

    private static func failures(_ events: [WriterEvent]) -> Int {
        events.filter { if case .failed = $0 { true } else { false } }.count
    }

    private static func isFailure(_ reason: WriterStopReason) -> Bool {
        if case .failed = reason { true } else { false }
    }

    /// The folder can't take the next part at a split (as when the drive is full or read-only): the recording stops
    /// there with a reason, and the part already written is kept, finished once, with its whole picture.
    @Test(arguments: [false, true])
    func aSplitWhoseNextPartCantOpenStopsAndKeepsTheFirst(sound: Bool) async throws {
        let dir = try WriterFixture.makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let writer = RecordingWriter(configuration: Self.configuration(dir, sound: sound))
        try writer.start(at: .zero)
        let stopped = await Self.feed(writer, frames: 0..<45, sound: sound) { index in
            if index == 29 { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path) }
        }
        #expect(stopped == 30, "the frame at the split finds the writer stopped")
        #expect(writer.append(audio: WriterFixture.makeAudio(track: 0, start: Self.time(30))) == false)
        let result = await writer.finish()
        let events = await collect(writer.events)

        #expect(Self.isFailure(result.stopReason))
        #expect(result.files.map(\.lastPathComponent) == ["take.mov"])
        #expect(Self.finishedIndices(events) == [1], "the first part is finished once")
        #expect(Self.failures(events) == 1)
        let info = try await MovieInfo.load(try #require(result.files.first))
        #expect(info.videoSampleCount == 30)
        #expect(info.audioTracks.count == (sound ? 2 : 0))
    }

    /// The folder is gone when the next part should begin: the recording stops there with a reason, and nothing makes
    /// the folder again (an unplugged drive's folder would come back on the startup disk).
    @Test(arguments: [false, true])
    func aFolderGoneAtTheStartOfAPartStopsCleanly(sound: Bool) async throws {
        let parent = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("Recordings", isDirectory: true)
        let writer = RecordingWriter(configuration: Self.configuration(dir, sound: sound))
        try writer.start(at: .zero)
        let stopped = await Self.feed(writer, frames: 0..<45, sound: sound) { index in
            if index == 29 { try? FileManager.default.removeItem(at: dir) }
        }
        #expect(stopped == 30)
        let result = await writer.finish()
        let events = await collect(writer.events)

        #expect(Self.isFailure(result.stopReason))
        #expect(result.files.isEmpty, "the part went with its folder, so no file is offered")
        #expect(Self.finishedIndices(events) == [1])
        #expect(Self.failures(events) == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// The part being written fails partway through (a disk that fills faster than the free-space check sees, an
    /// unplugged drive): the recording stops with a reason, both parts are finished once, the part before is kept
    /// whole and the failed one is kept with what reached it.
    @Test(arguments: [false, true])
    func aDiskThatFillsMidPartStopsAndKeepsTheParts(sound: Bool) async throws {
        let dir = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingWriter(configuration: Self.configuration(dir, sound: sound, split: 1))
        try writer.start(at: .zero)
        // Part 2 begins at frame 30 and fails two frames in, while part 1 may still wait for its sound.
        let stopped = await Self.feed(writer, frames: 0..<150, sound: sound) { index in
            if index == 32 { writer.failCurrentPartForTesting() }
        }
        #expect(stopped != nil, "the failed part stops the writer")
        #expect(writer.append(frame: WriterFixture.makeFrame(index: 200), at: Self.time(200)) == .stopped)
        let result = await writer.finish()
        let events = await collect(writer.events)

        #expect(Self.isFailure(result.stopReason))
        #expect(result.files.map(\.lastPathComponent) == ["take.mov", "take part 2.mov"])
        #expect(Self.finishedIndices(events).sorted() == [1, 2], "each part is finished once")
        #expect(Self.failures(events) == 1)
        let first = try await MovieInfo.load(result.files[0])
        #expect(first.videoSampleCount == 30)
        #expect(first.audioTracks.count == (sound ? 2 : 0))
    }

    /// The same without splitting: the only part fails partway through, stops the writer once and is kept.
    @Test func aDiskThatFillsInAnUnsplitRecordingStopsOnce() async throws {
        let dir = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = RecordingWriter(configuration: Self.configuration(dir, sound: true, split: nil))
        try writer.start(at: .zero)
        let stopped = await Self.feed(writer, frames: 0..<150, sound: true) { index in
            if index == 10 { writer.failCurrentPartForTesting() }
        }
        #expect(stopped != nil)
        let result = await writer.finish()
        let again = await writer.finish()
        let events = await collect(writer.events)

        #expect(Self.isFailure(result.stopReason))
        #expect(again.stopReason == result.stopReason)
        #expect(result.files.map(\.lastPathComponent) == ["take.mov"])
        #expect(Self.finishedIndices(events) == [1])
        #expect(Self.failures(events) == 1)
    }
}
