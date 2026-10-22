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

    private func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
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

    // MARK: Saving

    @Test func aTypedNameThatsTakenGetsTheNextNumber() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mov = try place("Seed 1.mov", in: directory)
        let mp4 = try place("Seed 1.mp4", in: directory)
        let two = try place("Seed 1 2.mp4", in: directory)
        let asMov = await RecordingFinisher.save(try await record("a", in: directory), name: "Seed 1", as: .mov)
        #expect(asMov.files.map(\.lastPathComponent) == ["Seed 1 3.mov"])
        let asMP4 = await RecordingFinisher.save(try await record("b", in: directory), name: "Seed 1", as: .mp4)
        #expect(asMP4.problems.isEmpty)
        #expect(asMP4.files.map(\.lastPathComponent) == ["Seed 1 4.mp4"])
        #expect(untouched(mov) && untouched(mp4) && untouched(two))
    }

    /// Typing the name of the recording itself keeps it where it is.
    @Test func typingItsOwnNameKeepsIt() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try await record(Self.date, in: directory, split: 0.3)
        let saved = await RecordingFinisher.save(files, name: Self.date, as: .mov)
        #expect(saved.files == files)
        #expect(saved.problems.isEmpty)
    }

    /// Split parts move together: every part gets the same free name, numbered after it.
    @Test func splitPartsShareOneFreeName() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = try place("Run.mov", in: directory)
        let olderPart = try place("Run part 2.mov", in: directory)
        let onlyAPart = try place("Run 2 part 3.mp4", in: directory)
        let files = try await record(Self.date, in: directory, split: 0.3)
        #expect(files.count == 2)
        let saved = await RecordingFinisher.save(files, name: "Run", as: .mov)
        #expect(saved.files.map(\.lastPathComponent) == ["Run 3.mov", "Run 3 part 2.mov"])
        #expect(untouched(older) && untouched(olderPart) && untouched(onlyAPart))
    }

    /// Kept under its date-and-time name as .mp4, a recording whose .mp4 name is taken moves on, every part with it.
    @Test func theDateNameMovesOnWhenItsMP4IsTaken() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try await record("D", in: directory, split: 0.3)
        #expect(files.map(\.lastPathComponent) == ["D.mov", "D part 2.mov"])
        let squatter = try place("D.mp4", in: directory)
        let saved = await RecordingFinisher.save(files, name: nil, as: .mp4)
        #expect(saved.problems.isEmpty)
        #expect(saved.files.map(\.lastPathComponent) == ["D 2.mp4", "D 2 part 2.mp4"])
        #expect(untouched(squatter))
    }

    /// Names differing only in case are the same file on macOS' usual volumes, so they're taken too.
    @Test func aNameDifferingOnlyInCaseIsTaken() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = try place("seed 1.mov", in: directory)
        let saved = await RecordingFinisher.save(try await record("a", in: directory), name: "SEED 1", as: .mov)
        #expect(saved.files.map(\.lastPathComponent) == ["SEED 1 2.mov"])
        #expect(untouched(other))
    }

    /// The .mp4 is never written over a file that's already there, and that file is never removed.
    @Test func rewrappingNeverReplacesAFile() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mov = try #require(try await record("a", in: directory).first)
        let there = try place("there.mp4", in: directory)
        await #expect(throws: RewrapError.self) { try await Rewrapper.rewrap(from: mov, to: there) }
        #expect(untouched(there))
        #expect(names(in: directory) == ["a.mov", "there.mp4"])
    }

    /// What the question says Save and Esc will do names the file they'll really make.
    @Test func thePlannedNamesAreTheSavedOnes() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try place("Seed 1.mp4", in: directory)
        _ = try place("\(Self.date).mp4", in: directory)
        let files = try await record(Self.date, in: directory)
        #expect(RecordingFinisher.plannedFiles(for: files, name: "Seed 1", as: .mp4).map(\.lastPathComponent) == ["Seed 1 2.mp4"])
        #expect(RecordingFinisher.plannedFiles(for: files, name: "  ", as: .mp4).map(\.lastPathComponent) == ["\(Self.date) 2.mp4"])
        #expect(RecordingFinisher.plannedFiles(for: files, name: nil, as: .mov) == files)
        let saved = await RecordingFinisher.save(files, name: "Seed 1", as: .mp4)
        #expect(saved.files.map(\.lastPathComponent) == ["Seed 1 2.mp4"])
    }
}
