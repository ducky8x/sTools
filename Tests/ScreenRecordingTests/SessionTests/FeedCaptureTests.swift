import CoreMedia
import Foundation
import os
import STPlatform
import Testing
@testable import ScreenRecording

/// Collects what a capture delivers.
private final class Chunks: Sendable {
    private let chunks = OSAllocatedUnfairLock<[AudioChunk]>(initialState: [])
    var all: [AudioChunk] { chunks.withLock { $0 } }
    func add(_ chunk: AudioChunk) { chunks.withLock { $0.append(chunk) } }
}

/// The host clock's ticks for `seconds`, as an audio tap stamps a buffer.
func hostTicks(_ seconds: Double) -> UInt64 {
    CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
}

@Suite("Feed capture")
struct FeedCaptureTests {
    @Test func itListensFromStartToStop() async throws {
        let feed = InProcessAudio().feed(named: "Timer alarm")
        let capture = FeedCapture(feed: feed)
        let chunks = Chunks()
        #expect(!feed.hasListeners)
        try await capture.start { chunks.add($0) }
        #expect(feed.hasListeners)
        feed.publish(InProcessAudioBuffer(samples: [0.1, -0.1, 0.2, -0.2], sampleRate: 48_000, channelCount: 2, hostTime: hostTicks(12)))
        await capture.stop()
        #expect(!feed.hasListeners)
        feed.publish(InProcessAudioBuffer(samples: [0.3, 0.3], sampleRate: 48_000, channelCount: 2, hostTime: hostTicks(13)))

        let chunk = try #require(chunks.all.first)
        #expect(chunks.all.count == 1)
        #expect(chunk.samples == [0.1, -0.1, 0.2, -0.2])
        #expect(chunk.sampleRate == 48_000)
        #expect(chunk.channelCount == 2)
        #expect(abs(CMTimeGetSeconds(chunk.hostTime) - 12) < 0.000_01)
    }

    /// Chunks keep the buffer's host time and arrive as the buffer is published, so they're far inside
    /// `RecordingSession.audioLag`.
    @Test func aChunkKeepsTheBuffersHostTimeAndArrivesAtOnce() async throws {
        let feed = InProcessAudio().feed(named: "Timer alarm")
        let capture = FeedCapture(feed: feed)
        let chunks = Chunks()
        try await capture.start { chunks.add($0) }
        defer { Task { await capture.stop() } }
        let ticks = hostTicks(345.678)
        feed.publish(InProcessAudioBuffer(samples: [Float](repeating: 0.5, count: 512), sampleRate: 44_100, channelCount: 1, hostTime: ticks))
        let chunk = try #require(chunks.all.first)
        #expect(CMClockConvertHostTimeToSystemUnits(chunk.hostTime) == ticks)
        #expect(chunk.frameCount == 512)
        #expect(chunk.sampleRate == 44_100)
    }

    @Test func unusableBuffersAreDropped() {
        #expect(FeedCapture.chunk(from: InProcessAudioBuffer(samples: [], sampleRate: 48_000, channelCount: 2, hostTime: 1)) == nil)
        #expect(FeedCapture.chunk(from: InProcessAudioBuffer(samples: [1, 1], sampleRate: 0, channelCount: 2, hostTime: 1)) == nil)
        #expect(FeedCapture.chunk(from: InProcessAudioBuffer(samples: [1, 1], sampleRate: .nan, channelCount: 2, hostTime: 1)) == nil)
        #expect(FeedCapture.chunk(from: InProcessAudioBuffer(samples: [1, 1], sampleRate: 48_000, channelCount: 0, hostTime: 1)) == nil)
        #expect(FeedCapture.chunk(from: InProcessAudioBuffer(samples: [1], sampleRate: 48_000, channelCount: 2, hostTime: 1)) == nil)
    }

    @Test func startingTwiceKeepsOneListener() async throws {
        let feed = InProcessAudio().feed(named: "Timer alarm")
        let capture = FeedCapture(feed: feed)
        let chunks = Chunks()
        try await capture.start { chunks.add($0) }
        try await capture.start { chunks.add($0) }
        feed.publish(InProcessAudioBuffer(samples: [0.1, 0.1], sampleRate: 48_000, channelCount: 2, hostTime: hostTicks(1)))
        #expect(chunks.all.count == 1)
        await capture.stop()
        #expect(!feed.hasListeners)
    }
}
