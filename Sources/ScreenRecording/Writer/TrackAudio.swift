import CoreMedia
import Foundation

/// A finished block of 48 kHz stereo Float32 audio for one output track of the recording file.
public struct TrackAudio: Sendable, Equatable {
    public static let sampleRate = 48_000
    public static let channelCount = 2

    /// 0 is the mix (file track 1); 1...n are the individual sources (file tracks 2...n+1).
    public let track: Int
    /// Presentation time of the first frame, on the same clock as the video frames.
    public let time: CMTime
    /// Interleaved left/right samples; the count is always twice the frame count.
    public let samples: [Float]

    public init(track: Int, time: CMTime, samples: [Float]) {
        self.track = track
        self.time = time
        self.samples = samples
    }

    public var frameCount: Int { samples.count / Self.channelCount }

    public var duration: CMTime {
        CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(Self.sampleRate))
    }

    public var endTime: CMTime { time + duration }
}
