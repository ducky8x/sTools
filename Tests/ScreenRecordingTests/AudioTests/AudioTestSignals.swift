import CoreMedia
import Foundation
@testable import ScreenRecording

enum AudioTestSignals {
    /// Interleaved sine, the same value on every channel.
    static func sine(frequency: Double, amplitude: Float, rate: Double, channels: Int = 2, frames: Int, startFrame: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(startFrame + i) / rate))
            for c in 0..<channels { out[i * channels + c] = v }
        }
        return out
    }

    /// A normalized stereo chunk holding `value` in every sample.
    static func constant(_ value: Float, frames: Int, at seconds: Double) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: value, count: frames * 2), sampleRate: 48_000, channelCount: 2, hostTime: .seconds(seconds))
    }

    /// A normalized stereo chunk whose left and right samples count up from `first`, so tests can tell which frames survive.
    static func ramp(first: Int, frames: Int, at seconds: Double) -> AudioChunk {
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { samples[i * 2] = Float(first + i); samples[i * 2 + 1] = Float(first + i) }
        return AudioChunk(samples: samples, sampleRate: 48_000, channelCount: 2, hostTime: .seconds(seconds))
    }

    static func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }
}
