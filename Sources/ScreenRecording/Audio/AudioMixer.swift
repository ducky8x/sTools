import Foundation

/// Names a source's audio track.
public enum AudioTrackID: Hashable, Sendable {
    case minecraft
    /// The sound of the web pages on the canvas, all together (spec 5.4.1).
    case webPages
    case source(UUID)
    /// sTools' own sound from the in-process feed with this name, such as *Timer alarm* (`InProcessAudio`).
    case feed(String)
}

/// Keeps a summed signal inside -1...1 without the harsh flat top of hard clipping: samples below the knee
/// pass unchanged, louder ones bend smoothly toward 1 (`tanh`, matched in value and slope at the knee).
public enum SoftLimiter {
    public static let knee: Float = 0.8

    public static func process(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let room = 1 - knee
        let limited = knee + room * Float(tanh(Double((magnitude - knee) / room)))
        return sample < 0 ? -limited : limited
    }
}

/// What one mixing call produced.
public struct AudioMix: Equatable, Sendable {
    /// Track 1: every source at its gain, summed and soft limited.
    public var mix: [Float]
    /// Tracks 2...n: each source unmixed (unity gain), padded with silence to the length of the mix.
    public var tracks: [AudioTrackID: [Float]]
}

/// Sums aligned 48 kHz stereo blocks with per-source gain.
public struct AudioMixer: Sendable {
    private var gains: [AudioTrackID: Float]

    public init(gains: [AudioTrackID: Float] = [:]) {
        self.gains = gains.mapValues(Self.sanitize)
    }

    /// 1 for a source that was never given a gain.
    public func gain(for id: AudioTrackID) -> Float { gains[id] ?? 1 }

    public mutating func setGain(_ gain: Float, for id: AudioTrackID) {
        gains[id] = Self.sanitize(gain)
    }

    /// `inputs` holds each source's samples for the same span of time. Shorter inputs are padded with silence.
    public func mix(_ inputs: [AudioTrackID: [Float]]) -> AudioMix {
        let length = inputs.values.map(\.count).max() ?? 0
        var sum = [Float](repeating: 0, count: length)
        var tracks: [AudioTrackID: [Float]] = [:]
        for (id, samples) in inputs {
            let gain = gain(for: id)
            var clean = samples
            for i in clean.indices where !clean[i].isFinite { clean[i] = 0 }
            for i in clean.indices { sum[i] += clean[i] * gain }
            if clean.count < length { clean.append(contentsOf: repeatElement(0, count: length - clean.count)) }
            tracks[id] = clean
        }
        return AudioMix(mix: sum.map(SoftLimiter.process), tracks: tracks)
    }

    private static func sanitize(_ gain: Float) -> Float {
        gain.isFinite ? max(0, gain) : 1
    }
}
