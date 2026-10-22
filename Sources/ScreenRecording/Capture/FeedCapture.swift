import CoreMedia
import Foundation
import os
import STPlatform

/// sTools' own sound from an in-process feed (`InProcessAudioFeed`), such as Timer Overlay's alarm: the *Timer
/// alarm* track (spec 5.4.1). It listens to the feed from `start` to `stop` and hands each buffer on at once, on the
/// publisher's thread, stamped with the buffer's own host time, so it reaches the mix well within
/// `RecordingSession.audioLag`. Nothing here asks for a permission or starts any capture.
public final class FeedCapture: AudioCapture, @unchecked Sendable {
    public let feed: InProcessAudioFeed
    private let token = OSAllocatedUnfairLock<InProcessAudioFeed.ListenerToken?>(initialState: nil)

    public init(feed: InProcessAudioFeed) {
        self.feed = feed
    }

    public func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws {
        let listener = feed.addListener { buffer in
            if let chunk = Self.chunk(from: buffer) { deliver(chunk) }
        }
        let old = token.withLock { token in
            defer { token = listener }
            return token
        }
        if let old { feed.removeListener(old) }
    }

    public func stop() async {
        if let listener = token.withLock({ token in defer { token = nil }; return token }) {
            feed.removeListener(listener)
        }
    }

    /// A feed's buffer as a chunk on the host clock, or nil when it holds no whole frame or its format is unusable.
    static func chunk(from buffer: InProcessAudioBuffer) -> AudioChunk? {
        guard buffer.channelCount > 0, buffer.sampleRate.isFinite, buffer.sampleRate > 0, buffer.frameCount > 0 else { return nil }
        return AudioChunk(
            samples: buffer.samples, sampleRate: buffer.sampleRate, channelCount: buffer.channelCount,
            hostTime: CMClockMakeHostTimeFromSystemUnits(buffer.hostTime))
    }
}
