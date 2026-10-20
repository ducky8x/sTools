import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

@Suite("Recording finisher", .serialized)
struct RecordingFinisherTests {
    private func record(_ name: String, in directory: URL) async throws -> URL {
        let writer = RecordingWriter(configuration: WriterFixture.configuration(directory, base: name))
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 15)
        return try #require(await writer.finish().files.first)
    }

    @Test func unnamedRecordingsAreNamedByDateAndTime() {
        let date = Date(timeIntervalSince1970: 1_791_925_477)
        #expect(RecordingFinisher.dateName(for: date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-13 21.04.37")
    }

    @Test func typedNamesAreMadeSafe() {
        #expect(RecordingFinisher.sanitizedName("  any% PB: 14:02/RSG ") == "any% PB- 14-02-RSG")
        #expect(RecordingFinisher.sanitizedName("..hidden") == "hidden")
        #expect(RecordingFinisher.sanitizedName("   ") == nil)
    }

    @Test func savingAsMP4RewrapsAndRemovesTheMov() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mov = try await record("2026-10-19 17.00.00", in: directory)
        let result = await RecordingFinisher.save([mov], name: "First Try", as: .mp4)
        #expect(result.problems.isEmpty)
        #expect(result.files.map(\.lastPathComponent) == ["First Try.mp4"])
        #expect(!FileManager.default.fileExists(atPath: mov.path))
        #expect(try await MovieInfo.load(result.files[0]).videoSampleCount == 15)
    }

    @Test func savingAsMovKeepsTheDateNameWhenUnnamedAndAvoidsClashes() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await record("a", in: directory)
        let kept = await RecordingFinisher.save([first], name: nil, as: .mov)
        #expect(kept.files == [first])
        let second = try await record("b", in: directory)
        let renamed = await RecordingFinisher.save([second], name: "a", as: .mov)
        #expect(renamed.files.map(\.lastPathComponent) == ["a 2.mov"])
    }

    @Test func splitPartsAreNumbered() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let one = try await record("x", in: directory), two = try await record("x part 2", in: directory)
        let result = await RecordingFinisher.save([one, two], name: "Run", as: .mov)
        #expect(result.files.map(\.lastPathComponent) == ["Run.mov", "Run part 2.mov"])
    }

    @Test func aFileThatCantBeRewrappedStaysMov() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.mov")
        try Data("not a movie".utf8).write(to: broken)
        let result = await RecordingFinisher.save([broken], name: "Named", as: .mp4)
        #expect(result.files.map(\.lastPathComponent) == ["Named.mov"])
        #expect(result.problems.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Named.mp4").path))
    }

    @Test func deleteRemovesEverything() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await record("gone", in: directory)
        RecordingFinisher.delete([file])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct RewrapVerificationTests {
    private func info(audio: [(String, Int)], video: Int = 30, duration: Double = 1) -> MovieInfo {
        MovieInfo(duration: duration, nominalFrameRate: 30, videoCodec: "avc1", videoSampleCount: video,
                  audioTracks: audio.map { MovieInfo.AudioTrackInfo(title: $0.0, sampleCount: $0.1) })
    }

    @Test func oneTailAudioPacketIsTolerated() throws {
        try Rewrapper.verify(info(audio: [("Mix", 28), ("Minecraft", 28)]), info(audio: [("Mix", 27), ("Minecraft", 27)]))
    }

    @Test func realDifferencesAreRefused() {
        #expect(throws: RewrapError.self) { try Rewrapper.verify(info(audio: [("Mix", 28)]), info(audio: [("Mix", 25)])) }
        #expect(throws: RewrapError.self) { try Rewrapper.verify(info(audio: [("Mix", 28)]), info(audio: [("Other", 28)])) }
        #expect(throws: RewrapError.self) { try Rewrapper.verify(info(audio: [("Mix", 28)]), info(audio: [])) }
        #expect(throws: RewrapError.self) { try Rewrapper.verify(info(audio: [], video: 30), info(audio: [], video: 29)) }
    }
}
