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
    /// Set once the video sources were stopped, so a full stop after `stopVideo()` doesn't stop them twice.
    private let videoStopped = OSAllocatedUnfairLock(initialState: false)
    /// The pictures whose capture started.
    private let startedVideo = OSAllocatedUnfairLock(initialState: Set<SourceKey>())

    public init(video: [SourceKey: any VideoCapture], audio: [AudioTrackID: any AudioCapture], minimizedShowsNothing: Bool) {
        self.video = video
        self.audio = audio
        self.minimizedShowsNothing = minimizedShowsNothing
        (events, continuation) = AsyncStream<RigEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public var videoKeys: Set<SourceKey> { Set(video.keys) }
    public var audioTracks: Set<AudioTrackID> { Set(audio.keys) }

    /// Whether `key`'s capture started (and so may deliver frames).
    public func hasStarted(_ key: SourceKey) -> Bool {
        startedVideo.withLock { $0.contains(key) }
    }

    /// Starts every source at once, so switching the tool on waits for the slowest one rather than for each in turn
    /// (spec 5.4.4); one that fails is reported and left out.
    public func start() async {
        await withTaskGroup(of: Void.self) { group in
            for (key, capture) in video {
                group.addTask { await self.start(key, capture) }
            }
            for (id, capture) in audio {
                group.addTask { await self.start(id, capture) }
            }
        }
    }

    private func start(_ key: SourceKey, _ capture: any VideoCapture) async {
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
            startedVideo.withLock { _ = $0.insert(key) }
            continuation.yield(.started(key))
        } catch {
            continuation.yield(.failedToStart(key, error.localizedDescription))
        }
    }

    private func start(_ id: AudioTrackID, _ capture: any AudioCapture) async {
        let bus = bus
        do {
            try await capture.start { chunk in bus.withLock { $0 }?.ingest(chunk, for: id) }
        } catch {
            continuation.yield(.audioFailedToStart(id, error.localizedDescription))
        }
    }

    /// Stops every source and lets go of their frames; the event stream ends.
    public func stop() async {
        attach(nil)
        await stopVideo()
        for capture in audio.values { await capture.stop() }
        hub.removeAll()
        continuation.finish()
    }

    /// Stops the windows, displays, cameras, browser sources and Minecraft's capture, and leaves the sound running: a
    /// recording that stops needs no more pictures, but its last samples are still on their way (spec 5.4.4). The
    /// frames they left stay in the hub until `stop()`.
    public func stopVideo() async {
        let alreadyStopped = videoStopped.withLock { stopped in
            defer { stopped = true }
            return stopped
        }
        guard !alreadyStopped else { return }
        for capture in video.values { await capture.stop() }
    }

    /// Routes sound to `bus` (a starting recording) or nowhere (`nil`).
    public func attach(_ bus: AudioMixBus?) {
        self.bus.withLock { $0 = bus }
    }

    /// Stops routing sound to `bus`, if it's still the one sound goes to: a recording that's done never takes the
    /// sound from one that started after it.
    public func detach(_ bus: AudioMixBus) {
        self.bus.withLock { attached in
            if attached === bus { attached = nil }
        }
    }
}
