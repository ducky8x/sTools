import Foundation
import os

/// Something a capture source reported that the page should show (spec 5.4.6).
public enum RigEvent: Sendable, Equatable {
    /// A source started.
    case started(SourceKey)
    /// A source could not start; the slot stays empty.
    case failedToStart(SourceKey, String)
    /// A source ended (window closed, device gone); its slot is empty from now on.
    case ended(SourceKey, String)
    case audioFailedToStart(AudioTrackID, String)
}

/// Runs the capture sources while the recorder is armed. Frames land in `hub`, which the live preview and a
/// running recording both read; sound goes to the recording's mix bus while one is attached and is dropped
/// otherwise (nothing needs it before Record).
public final class CaptureRig: @unchecked Sendable {
    public let hub = FrameHub()
    public let events: AsyncStream<RigEvent>

    private let continuation: AsyncStream<RigEvent>.Continuation
    private let video: [SourceKey: any VideoCapture]
    private let audio: [AudioTrackID: any AudioCapture]
    private let minimizedShowsNothing: Bool
    private let bus = OSAllocatedUnfairLock<AudioMixBus?>(initialState: nil)

    public init(video: [SourceKey: any VideoCapture], audio: [AudioTrackID: any AudioCapture], minimizedShowsNothing: Bool) {
        self.video = video
        self.audio = audio
        self.minimizedShowsNothing = minimizedShowsNothing
        (events, continuation) = AsyncStream<RigEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public var videoKeys: Set<SourceKey> { Set(video.keys) }
    public var audioTracks: Set<AudioTrackID> { Set(audio.keys) }

    /// Starts every source; one that fails is reported and left out.
    public func start() async {
        for (key, capture) in video {
            let hub = hub
            let continuation = continuation
            let hidesWhenMinimized = minimizedShowsNothing
            do {
                try await capture.start { event in
                    switch event {
                    case .frame(let frame): hub.submit(frame, for: key)
                    case .minimized(let minimized): if hidesWhenMinimized { hub.setHidden(minimized, for: key) }
                    case .ended(let reason):
                        hub.clear(key)
                        continuation.yield(.ended(key, reason))
                    }
                }
                continuation.yield(.started(key))
            } catch {
                continuation.yield(.failedToStart(key, error.localizedDescription))
            }
        }
        for (id, capture) in audio {
            let bus = bus
            do {
                try await capture.start { chunk in bus.withLock { $0 }?.ingest(chunk, for: id) }
            } catch {
                continuation.yield(.audioFailedToStart(id, error.localizedDescription))
            }
        }
    }

    public func stop() async {
        attach(nil)
        for capture in video.values { await capture.stop() }
        for capture in audio.values { await capture.stop() }
        hub.removeAll()
        continuation.finish()
    }

    /// Routes sound to `bus` (a starting recording) or nowhere (`nil`).
    public func attach(_ bus: AudioMixBus?) {
        self.bus.withLock { $0 = bus }
    }
}
