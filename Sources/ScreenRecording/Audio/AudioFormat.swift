import CoreMedia
import Foundation

/// The one format every audio source is converted to before timing and mixing: 48 kHz, stereo, Float32,
/// interleaved (`L R L R ...`).
public enum AudioFormat {
    public static let sampleRate = 48_000.0
    public static let channelCount = 2
}

/// A run of interleaved Float32 samples as a source delivered it.
public struct AudioChunk: Equatable, Sendable {
    /// Interleaved samples; `samples.count` is a multiple of `channelCount`.
    public var samples: [Float]
    public var sampleRate: Double
    public var channelCount: Int
    /// When the first frame was captured, on the host clock.
    public var hostTime: CMTime

    public init(samples: [Float], sampleRate: Double, channelCount: Int, hostTime: CMTime) {
        let channels = max(1, channelCount)
        self.samples = samples.count % channels == 0 ? samples : Array(samples.dropLast(samples.count % channels))
        self.sampleRate = sampleRate
        self.channelCount = channels
        self.hostTime = hostTime
    }

    /// Builds a chunk from one array per channel (what `AVAudioPCMBuffer.floatChannelData` holds).
    /// Channels shorter than the longest are padded with silence.
    public init(planar channels: [[Float]], sampleRate: Double, hostTime: CMTime) {
        let count = max(1, channels.count)
        let frames = channels.map(\.count).max() ?? 0
        var interleaved = [Float](repeating: 0, count: frames * count)
        for (c, channel) in channels.enumerated() {
            for (i, value) in channel.enumerated() { interleaved[i * count + c] = value }
        }
        self.init(samples: interleaved, sampleRate: sampleRate, channelCount: count, hostTime: hostTime)
    }

    public var frameCount: Int { samples.count / channelCount }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    public var isNormalized: Bool { sampleRate == AudioFormat.sampleRate && channelCount == AudioFormat.channelCount }
}

/// Converts chunks to `AudioFormat`. Keep one per source: resampling carries state from chunk to chunk, so
/// a stream cut into chunks resamples exactly like the same stream in one piece.
///
/// Channels: mono is duplicated to both sides; with three or more channels only the first two are kept
/// (process taps and microphones deliver mono or stereo). Resampling is linear interpolation, which is
/// cheap, deterministic and free of the priming delay a converter object adds to timestamps; it is good
/// enough for speech and game sound at the 44.1/48/96 kHz rates devices use.
public struct AudioNormalizer: Sendable {
    private var inputRate: Double = 0
    private var phase = 0.0
    private var carry: [Float]?

    public init() {}

    /// The chunk as 48 kHz stereo. The result keeps the input's `hostTime`; samples carried over from an
    /// earlier chunk are not added to the front, so `hostTime` stays the stamp of the first sample returned
    /// for streams whose rate does not change.
    public mutating func normalize(_ chunk: AudioChunk) -> AudioChunk {
        let stereo = Self.toStereo(chunk.samples, channels: chunk.channelCount)
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0, chunk.sampleRate != AudioFormat.sampleRate else {
            reset()
            return AudioChunk(samples: stereo, sampleRate: AudioFormat.sampleRate, channelCount: 2, hostTime: chunk.hostTime)
        }
        if chunk.sampleRate != inputRate { reset(); inputRate = chunk.sampleRate }
        let out = resample(stereo, step: chunk.sampleRate / AudioFormat.sampleRate)
        return AudioChunk(samples: out, sampleRate: AudioFormat.sampleRate, channelCount: 2, hostTime: chunk.hostTime)
    }

    /// Forgets resampling state (call after a gap or a device change).
    public mutating func reset() {
        inputRate = 0
        phase = 0
        carry = nil
    }

    static func toStereo(_ samples: [Float], channels: Int) -> [Float] {
        switch channels {
        case 2:
            return samples
        case 1:
            var out = [Float](repeating: 0, count: samples.count * 2)
            for (i, v) in samples.enumerated() { out[i * 2] = v; out[i * 2 + 1] = v }
            return out
        default:
            let frames = samples.count / channels
            var out = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                out[i * 2] = samples[i * channels]
                out[i * 2 + 1] = samples[i * channels + 1]
            }
            return out
        }
    }

    /// `phase` is where the next output sample sits, counted in input frames from the carried-over frame
    /// (index 0 when there is one, otherwise from the first new frame).
    private mutating func resample(_ stereo: [Float], step: Double) -> [Float] {
        let newFrames = stereo.count / 2
        guard newFrames > 0 else { return [] }
        var input = carry ?? []
        input.append(contentsOf: stereo)
        let frames = input.count / 2
        var out: [Float] = []
        out.reserveCapacity(Int(Double(newFrames) / step) + 2)
        var position = phase
        while true {
            let index = Int(position)
            guard index + 1 < frames else { break }
            let fraction = Float(position - Double(index))
            for c in 0..<2 {
                let a = input[index * 2 + c], b = input[(index + 1) * 2 + c]
                out.append(a + (b - a) * fraction)
            }
            position += step
        }
        carry = Array(input[((frames - 1) * 2)...])
        phase = position - Double(frames - 1)
        return out
    }
}
