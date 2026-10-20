import CoreMedia
import Foundation
import os

/// A span of the recording's audio, every track the same length.
public struct AudioBlock: Equatable, Sendable {
    /// Recording frame of the first sample (frame 0 is the origin).
    public var startFrame: Int64
    public var frameCount: Int
    public var mix: [Float]
    public var tracks: [AudioTrackID: [Float]]

    /// Seconds after the recording origin.
    public var startSeconds: Double { Double(startFrame) / AudioFormat.sampleRate }
}

/// Collects every source's chunks, aligns them to the host clock and hands out equal-length blocks of the
/// mix and of each source. The writer pulls with `drain(upTo:)` on its own schedule; a source that has not
/// delivered by then is padded with silence for that span, and its late samples are trimmed when they arrive.
public final class AudioMixBus: @unchecked Sendable {
    private struct Lane {
        var normalizer = AudioNormalizer()
        var timeline: AudioTimeline
        /// Samples from the first frame not yet drained up to the timeline's end.
        var pending: [Float] = []
    }

    private struct State {
        var lanes: [AudioTrackID: Lane]
        var mixer: AudioMixer
        var emitted: Int64 = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let origin: CMTime

    public init(origin: CMTime, tracks: [AudioSourceTrack]) {
        self.origin = origin
        var lanes: [AudioTrackID: Lane] = [:]
        for track in tracks { lanes[track.id] = Lane(timeline: AudioTimeline(origin: origin)) }
        state = OSAllocatedUnfairLock(initialState: State(lanes: lanes, mixer: AudioSourceTrack.mixer(for: tracks)))
    }

    /// Normalizes and places a chunk from `id`. Chunks for an unknown track are ignored.
    public func ingest(_ chunk: AudioChunk, for id: AudioTrackID) {
        state.withLock { state in
            guard var lane = state.lanes[id] else { return }
            let placement = lane.timeline.place(lane.normalizer.normalize(chunk))
            lane.pending.append(contentsOf: placement.samples)
            state.lanes[id] = lane
        }
    }

    public func setGain(_ gain: Float, for id: AudioTrackID) {
        state.withLock { $0.mixer.setGain(gain, for: id) }
    }

    /// Everything from the last block up to `time` on the host clock, or nil if no whole frame is due.
    public func drain(upTo time: CMTime) -> AudioBlock? {
        let seconds = CMTimeGetSeconds(CMTimeSubtract(time, origin))
        guard seconds.isFinite, seconds > 0 else { return nil }
        return drain(toFrame: Int64((seconds * AudioFormat.sampleRate).rounded(.down)))
    }

    /// Emits what is left up to `time` and pads every track to it, so all tracks end together.
    public func finish(at time: CMTime) -> AudioBlock? { drain(upTo: time) }

    private func drain(toFrame target: Int64) -> AudioBlock? {
        state.withLock { state in
            let count = Int(target - state.emitted)
            guard count > 0 else { return nil }
            let channels = AudioFormat.channelCount
            var inputs: [AudioTrackID: [Float]] = [:]
            for (id, var lane) in state.lanes {
                lane.pending.append(contentsOf: lane.timeline.padSilence(to: target))
                inputs[id] = Array(lane.pending[0..<(count * channels)])
                lane.pending.removeFirst(count * channels)
                state.lanes[id] = lane
            }
            let mixed = state.mixer.mix(inputs)
            let start = state.emitted
            state.emitted = target
            return AudioBlock(startFrame: start, frameCount: count, mix: mixed.mix, tracks: mixed.tracks)
        }
    }
}
