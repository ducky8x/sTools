import Foundation
import Testing
@testable import ScreenRecording

@Suite("Reading movies back")
struct MovieReadingTests {
    /// More reads at once than the Swift concurrency pool has threads: every one of them finishes. A read waits for
    /// CoreMedia's own queues, and when every pool thread sat in a read there was nothing left for those queues to run
    /// on, so a Screen Recording test run on a busy Mac stuck for twenty minutes with all twelve threads in one.
    @Test(.timeLimit(.minutes(2)))
    func moreReadsThanThreadsAllFinish() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(configuration: WriterFixture.configuration(directory, audio: []))
        try writer.start(at: .zero)
        await WriterFixture.feed(writer, frames: 6, audioTracks: 0)
        let file = try #require(await writer.finish().files.first)

        let reads = max(48, ProcessInfo.processInfo.activeProcessorCount * 4)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<reads { group.addTask { try await MovieInfo.load(file).videoSampleCount } }
            var counts: [Int] = []
            for try await count in group { counts.append(count) }
            return counts
        }
        #expect(counts.count == reads)
        #expect(counts.allSatisfy { $0 == 6 })
    }
}
