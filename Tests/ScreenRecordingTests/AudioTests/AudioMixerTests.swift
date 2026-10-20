import Foundation
import Testing
@testable import ScreenRecording

@Suite struct AudioMixerTests {
    private let a = AudioTrackID.source(UUID())
    private let b = AudioTrackID.source(UUID())

    @Test func gainsScaleEachSourceBeforeSumming() {
        let mixer = AudioMixer(gains: [a: 1, b: 2])
        let out = mixer.mix([a: [0.25, -0.25], b: [0.25, 0.125]])
        #expect(out.mix == [0.75, 0.0])
    }

    @Test func unknownSourcesDefaultToUnityGain() {
        #expect(AudioMixer().gain(for: .minecraft) == 1)
        let out = AudioMixer().mix([.minecraft: [0.5]])
        #expect(out.mix == [0.5])
    }

    @Test func eachSourceIsAlsoReturnedUnmixedAtUnityGain() {
        var mixer = AudioMixer()
        mixer.setGain(0.5, for: a)
        let out = mixer.mix([a: [0.4, 0.4], b: [0.1]])
        #expect(out.tracks[a] == [0.4, 0.4])
        #expect(out.tracks[b] == [0.1, 0])
        #expect(out.mix.count == 2)
    }

    @Test func aMutedSourceLeavesTheMixButKeepsItsTrack() {
        let mixer = AudioMixer(gains: [a: 0])
        let out = mixer.mix([a: [0.9], b: [0.1]])
        #expect(out.mix == [0.1])
        #expect(out.tracks[a] == [0.9])
    }

    @Test func invalidGainsAreSanitized() {
        var mixer = AudioMixer(gains: [a: -3])
        #expect(mixer.gain(for: a) == 0)
        mixer.setGain(.nan, for: b)
        #expect(mixer.gain(for: b) == 1)
    }

    @Test func nonFiniteSamplesBecomeSilence() {
        let out = AudioMixer().mix([a: [.nan, .infinity, 0.5]])
        #expect(out.mix == [0, 0, 0.5])
        #expect(out.tracks[a] == [0, 0, 0.5])
    }

    @Test func twoSinesSumSampleForSample() {
        let s1 = AudioTestSignals.sine(frequency: 440, amplitude: 0.3, rate: 48_000, frames: 480)
        let s2 = AudioTestSignals.sine(frequency: 660, amplitude: 0.2, rate: 48_000, frames: 480)
        let out = AudioMixer().mix([a: s1, b: s2])
        #expect(AudioTestSignals.maxAbsDifference(out.mix, zip(s1, s2).map(+)) < 1e-6)
    }

    @Test func loudMixesNeverExceedFullScale() {
        let loud = [Float](repeating: 1.5, count: 100)
        let out = AudioMixer(gains: [a: 1.5, b: 1.5]).mix([a: loud, b: loud])
        #expect(out.mix.allSatisfy { $0 <= 1 && $0 > 0.99 })
        let negative = AudioMixer().mix([a: loud.map { -$0 }])
        #expect(negative.mix.allSatisfy { $0 >= -1 && $0 < -0.9 })
    }

    @Test func emptyInputGivesAnEmptyMix() {
        let out = AudioMixer().mix([:])
        #expect(out.mix.isEmpty && out.tracks.isEmpty)
    }
}

@Suite struct SoftLimiterTests {
    @Test func belowTheKneeSamplesAreUntouched() {
        for v in stride(from: Float(-0.8), through: 0.8, by: 0.05) { #expect(SoftLimiter.process(v) == v) }
    }

    @Test func isContinuousAtTheKnee() {
        let just = SoftLimiter.knee + 0.0001
        #expect(abs(SoftLimiter.process(just) - just) < 0.0002)
    }

    @Test func isMonotonicAndBoundedAndOdd() {
        var previous: Float = -1
        for i in 0...400 {
            let x = -5 + Float(i) * 0.025
            let y = SoftLimiter.process(x)
            #expect(y >= previous && abs(y) <= 1)
            #expect(y == -SoftLimiter.process(-x) || abs(y + SoftLimiter.process(-x)) < 1e-6)
            previous = y
        }
    }

    @Test func nonFiniteInputIsSilence() {
        #expect(SoftLimiter.process(.nan) == 0)
        #expect(SoftLimiter.process(-.infinity) == 0)
    }
}
