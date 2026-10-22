import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

/// A recording never takes a name that's already in its folder: a start, a split part and every save or rename pick
/// the next free name (`base 2`, `base 3`, as Finder does), and no file that was there is ever replaced or removed.
@Suite("Recording names never clash", .serialized)
struct RecordingNameClashTests {
    private static let date = "2026-10-22 13.12.28"

    private func record(_ base: String, in directory: URL, split: TimeInterval? = nil, frames: Int = 15) async throws -> [URL] {
        let writer = RecordingWriter(configuration: WriterFixture.configuration(directory, base: base, split: split))
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: frames)
        return await writer.finish().files
    }

    /// A stand-in for a recording that's already in the folder; its bytes show it was never replaced.
    private func place(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try Data("kept \(name)".utf8).write(to: url)
        return url
    }

    private func untouched(_ url: URL) -> Bool {
        (try? Data(contentsOf: url)) == Data("kept \(url.lastPathComponent)".utf8)
    }

    // MARK: Starting

    /// The bug: a recording kept under its date-and-time name made the next start in the same second fail.
    @Test func twoRecordingsInTheSameSecondBothStart() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await record(Self.date, in: directory)
        let kept = await RecordingFinisher.save(first, name: nil, as: .mov)
        #expect(kept.files.map(\.lastPathComponent) == ["\(Self.date).mov"])

        let second = try await record(Self.date, in: directory)
        #expect(second.map(\.lastPathComponent) == ["\(Self.date) 2.mov"])
        let third = try await record(Self.date, in: directory)
        #expect(third.map(\.lastPathComponent) == ["\(Self.date) 3.mov"])
        #expect(try await MovieInfo.load(first[0]).videoSampleCount == 15)
        #expect(try await MovieInfo.load(second[0]).videoSampleCount == 15)
    }

    /// A recording kept as .mp4 holds the name too, so the new one's .mov and its saved .mp4 agree.
    @Test func aSavedMP4HoldsItsNameForTheNextStart() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mp4 = try place("\(Self.date).mp4", in: directory)
        let files = try await record(Self.date, in: directory)
        #expect(files.map(\.lastPathComponent) == ["\(Self.date) 2.mov"])
        #expect(untouched(mp4))
    }

    /// A part left from an earlier split recording holds its whole name, so a new recording's parts never mix with it.
    @Test func anEarlierRecordingsPartHoldsItsName() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let part = try place("\(Self.date) part 2.mov", in: directory)
        let files = try await record(Self.date, in: directory, split: 0.3)
        #expect(files.map(\.lastPathComponent) == ["\(Self.date) 2.mov", "\(Self.date) 2 part 2.mov"])
        #expect(untouched(part))
    }

    /// A part whose name turns up in the folder while it records takes the next free name instead of failing.
    @Test func aSplitPartTakesTheNextFreeName() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(configuration: WriterFixture.configuration(directory, base: "take", split: 1))
        try writer.start(at: .zero)
        let squatter = try place("take part 2.mov", in: directory)
        await WriterFixture.feed(writer, frames: 45)
        let result = await writer.finish()
        #expect(result.stopReason == .finished)
        #expect(result.files.map(\.lastPathComponent) == ["take.mov", "take part 2 2.mov"])
        #expect(result.framesWritten == 45)
        #expect(untouched(squatter))
    }
}
