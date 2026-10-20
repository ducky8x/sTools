import CoreMedia
import Foundation

/// Where one chunk landed on a source's track.
public struct AudioPlacement: Equatable, Sendable {
    /// Interleaved 48 kHz stereo samples to append to the track: silence for any gap, then the chunk with
    /// any overlap cut off its front. May be empty.
    public var samples: [Float]
    /// The track frame the first returned sample belongs to (frame 0 is the recording origin).
    public var startFrame: Int64
    /// Frames of silence inserted before the chunk because it started later than the track had reached.
    public var paddedFrames: Int
    /// Frames cut from the front of the chunk because the track had already passed them.
    public var trimmedFrames: Int

    public var frameCount: Int { samples.count / AudioFormat.channelCount }
}

/// Lays one source's samples on the recording timeline, so every track is sample-aligned with the video
/// and with the other sources. Capture timestamps jitter by a few milliseconds even when no sample is lost,
/// so chunks that start within `tolerance` of where the track ends are treated as contiguous; only a larger
/// difference is corrected, by padding silence (gap) or trimming the chunk's head (overlap). A source whose
/// clock drifts therefore stays within `tolerance` of the host clock. The first chunk is always placed at
/// its own time, so the source's start is exact.
public struct AudioTimeline: Sendable {
    public let origin: CMTime
    /// Largest start-time error, in frames, that is left alone. 10 ms by default.
    public let toleranceFrames: Int
    /// Frames the track holds so far.
    public private(set) var endFrame: Int64 = 0
    public private(set) var totalPaddedFrames: Int64 = 0
    public private(set) var totalTrimmedFrames: Int64 = 0
    private var hasStarted = false

    public init(origin: CMTime, toleranceFrames: Int = 480) {
        self.origin = origin
        self.toleranceFrames = max(0, toleranceFrames)
    }

    /// Places an already normalized chunk (`AudioNormalizer`).
    public mutating func place(_ chunk: AudioChunk) -> AudioPlacement {
        let rate = AudioFormat.sampleRate
        let offset = CMTimeGetSeconds(CMTimeSubtract(chunk.hostTime, origin))
        let incoming = offset.isFinite ? Int64((offset * rate).rounded()) : endFrame
        let difference = incoming - endFrame
        let frames = Int64(chunk.frameCount)
        let start = endFrame

        let isFirst = !hasStarted
        hasStarted = true
        if !isFirst, abs(difference) <= Int64(toleranceFrames) {
            endFrame += frames
            return AudioPlacement(samples: chunk.samples, startFrame: start, paddedFrames: 0, trimmedFrames: 0)
        }
        if difference > 0 {
            let pad = Int(difference)
            totalPaddedFrames += difference
            endFrame += difference + frames
            let silence = [Float](repeating: 0, count: pad * AudioFormat.channelCount)
            return AudioPlacement(samples: silence + chunk.samples, startFrame: start, paddedFrames: pad, trimmedFrames: 0)
        }
        let trim = min(frames, -difference)
        totalTrimmedFrames += trim
        let kept = Array(chunk.samples[(Int(trim) * AudioFormat.channelCount)...])
        endFrame += frames - trim
        return AudioPlacement(samples: kept, startFrame: start, paddedFrames: 0, trimmedFrames: Int(trim))
    }

    /// Fills the track with silence up to `frame` (used when the mixer needs the track to reach a time the
    /// source has not delivered yet). Returns the silence; empty if the track is already that long.
    public mutating func padSilence(to frame: Int64) -> [Float] {
        guard frame > endFrame else { return [] }
        let count = Int(frame - endFrame)
        endFrame = frame
        totalPaddedFrames += Int64(count)
        return [Float](repeating: 0, count: count * AudioFormat.channelCount)
    }

    /// The track frame of a host time.
    public func frame(at time: CMTime) -> Int64 {
        let seconds = CMTimeGetSeconds(CMTimeSubtract(time, origin))
        return seconds.isFinite ? Int64((seconds * AudioFormat.sampleRate).rounded()) : 0
    }
}
