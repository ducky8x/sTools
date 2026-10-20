import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

@Suite struct AudioNormalizerTests {
    @Test func stereoAt48kPassesThroughUnchanged() {
        var n = AudioNormalizer()
        let samples = AudioTestSignals.sine(frequency: 440, amplitude: 0.5, rate: 48_000, frames: 1000)
        let out = n.normalize(AudioChunk(samples: samples, sampleRate: 48_000, channelCount: 2, hostTime: .seconds(3)))
        #expect(out.samples == samples)
        #expect(out.isNormalized)
        #expect(out.hostTime == .seconds(3))
    }

    @Test func monoIsDuplicatedToBothChannels() {
        var n = AudioNormalizer()
        let out = n.normalize(AudioChunk(samples: [0.1, 0.2, 0.3], sampleRate: 48_000, channelCount: 1, hostTime: .zero))
        #expect(out.samples == [0.1, 0.1, 0.2, 0.2, 0.3, 0.3])
    }

    @Test func surroundKeepsTheFirstTwoChannels() {
        var n = AudioNormalizer()
        let six: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        let out = n.normalize(AudioChunk(samples: six, sampleRate: 48_000, channelCount: 6, hostTime: .zero))
        #expect(out.samples == [1, 2, 7, 8])
    }

    @Test func aRaggedTailFrameIsDropped() {
        let chunk = AudioChunk(samples: [1, 2, 3, 4, 5], sampleRate: 48_000, channelCount: 2, hostTime: .zero)
        #expect(chunk.frameCount == 2)
    }

    @Test func planarChannelsAreInterleaved() {
        let chunk = AudioChunk(planar: [[1, 2, 3], [10, 20]], sampleRate: 48_000, hostTime: .zero)
        #expect(chunk.channelCount == 2)
        #expect(chunk.samples == [1, 10, 2, 20, 3, 0])
    }

    @Test func resampling44100To48000KeepsTheSineAndLength() {
        var n = AudioNormalizer()
        let input = AudioTestSignals.sine(frequency: 440, amplitude: 0.5, rate: 44_100, frames: 4410)
        let out = n.normalize(AudioChunk(samples: input, sampleRate: 44_100, channelCount: 2, hostTime: .zero))
        #expect(out.isNormalized)
        #expect(abs(out.frameCount - 4800) <= 1)
        let ideal = AudioTestSignals.sine(frequency: 440, amplitude: 0.5, rate: 48_000, frames: out.frameCount)
        #expect(AudioTestSignals.maxAbsDifference(out.samples, ideal) < 0.005)
    }

    @Test func rateRatiosGiveTheExpectedLengths() {
        for (rate, frames, expected) in [(8_000.0, 800, 4800), (96_000.0, 9600, 4800), (24_000.0, 2400, 4800)] {
            var n = AudioNormalizer()
            let out = n.normalize(AudioChunk(samples: [Float](repeating: 0.25, count: frames * 2), sampleRate: rate, channelCount: 2, hostTime: .zero))
            #expect(abs(out.frameCount - expected) <= 6)
            #expect(out.samples.allSatisfy { abs($0 - 0.25) < 1e-6 })
        }
    }

    @Test func aStreamCutIntoChunksResamplesLikeOnePiece() {
        let input = AudioTestSignals.sine(frequency: 300, amplitude: 0.6, rate: 24_000, frames: 2400)
        var whole = AudioNormalizer()
        let expected = whole.normalize(AudioChunk(samples: input, sampleRate: 24_000, channelCount: 2, hostTime: .zero)).samples

        var pieces = AudioNormalizer()
        var joined: [Float] = []
        var start = 0
        for size in [1, 7, 300, 1, 650, 1441] {
            let slice = Array(input[(start * 2)..<((start + size) * 2)])
            joined += pieces.normalize(AudioChunk(samples: slice, sampleRate: 24_000, channelCount: 2, hostTime: .zero)).samples
            start += size
        }
        #expect(joined.count == expected.count)
        #expect(AudioTestSignals.maxAbsDifference(joined, expected) < 1e-6)
    }

    @Test func chunkedAndWholeAgreeAt44100Too() {
        let input = AudioTestSignals.sine(frequency: 1000, amplitude: 0.4, rate: 44_100, frames: 4410)
        var whole = AudioNormalizer()
        let expected = whole.normalize(AudioChunk(samples: input, sampleRate: 44_100, channelCount: 2, hostTime: .zero)).samples
        var pieces = AudioNormalizer()
        var joined: [Float] = []
        for start in stride(from: 0, to: 4410, by: 441) {
            let slice = Array(input[(start * 2)..<((start + 441) * 2)])
            joined += pieces.normalize(AudioChunk(samples: slice, sampleRate: 44_100, channelCount: 2, hostTime: .zero)).samples
        }
        #expect(abs(joined.count - expected.count) <= 2)
        #expect(AudioTestSignals.maxAbsDifference(joined, expected) < 1e-3)
    }

    @Test func aRateChangeStartsFresh() {
        var n = AudioNormalizer()
        _ = n.normalize(AudioChunk(samples: [Float](repeating: 1, count: 200), sampleRate: 44_100, channelCount: 2, hostTime: .zero))
        let out = n.normalize(AudioChunk(samples: [Float](repeating: 0.5, count: 200), sampleRate: 16_000, channelCount: 2, hostTime: .zero))
        #expect(out.samples.allSatisfy { $0 == 0.5 })
    }

    @Test func emptyAndInvalidInputsDoNotCrash() {
        var n = AudioNormalizer()
        #expect(n.normalize(AudioChunk(samples: [], sampleRate: 44_100, channelCount: 2, hostTime: .zero)).samples.isEmpty)
        #expect(n.normalize(AudioChunk(samples: [0.5, 0.5], sampleRate: 0, channelCount: 2, hostTime: .zero)).samples == [0.5, 0.5])
    }
}
