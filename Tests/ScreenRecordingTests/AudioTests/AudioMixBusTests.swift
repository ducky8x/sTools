import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

@Suite struct AudioMixBusTests {
    private let mic = AudioTrackID.source(UUID())

    private func bus(origin: Double = 0, gains: (Double, Double) = (1, 1)) -> AudioMixBus {
        AudioMixBus(origin: .seconds(origin), tracks: [
            AudioSourceTrack(id: .minecraft, title: "Minecraft", volume: gains.0),
            AudioSourceTrack(id: mic, title: "Mic", volume: gains.1),
        ])
    }

    @Test func nothingIsDueBeforeAFullFrameHasPassed() {
        let b = bus(origin: 5)
        #expect(b.drain(upTo: .seconds(5)) == nil)
        #expect(b.drain(upTo: .seconds(4)) == nil)
    }

    @Test func blocksAreContiguousAndEqualLengthAcrossTracks() {
        let b = bus()
        b.ingest(AudioTestSignals.ramp(first: 0, frames: 4800, at: 0), for: .minecraft)
        b.ingest(AudioTestSignals.ramp(first: 0, frames: 4800, at: 0), for: mic)
        let first = b.drain(upTo: .seconds(0.05))
        let second = b.drain(upTo: .seconds(0.1))
        #expect(first?.startFrame == 0 && first?.frameCount == 2400)
        #expect(second?.startFrame == 2400 && second?.frameCount == 2400)
        #expect(first?.tracks[.minecraft]?.count == 4800 && first?.mix.count == 4800)
        #expect(second?.tracks[mic]?.first == 2400)
        #expect(second?.startSeconds == 0.05)
    }

    @Test func theMixSumsGainedSourcesAndTracksStayUnmixed() {
        let b = bus(gains: (1, 0.5))
        b.ingest(AudioTestSignals.constant(0.2, frames: 480, at: 0), for: .minecraft)
        b.ingest(AudioTestSignals.constant(0.4, frames: 480, at: 0), for: mic)
        let block = b.drain(upTo: .seconds(0.01))
        #expect(block?.mix.allSatisfy { abs($0 - 0.4) < 1e-6 } == true)
        #expect(block?.tracks[.minecraft]?.allSatisfy { $0 == 0.2 } == true)
        #expect(block?.tracks[mic]?.allSatisfy { abs($0 - 0.4) < 1e-6 } == true)
        b.setGain(0, for: mic)
        b.ingest(AudioTestSignals.constant(0.2, frames: 480, at: 0.01), for: .minecraft)
        b.ingest(AudioTestSignals.constant(0.4, frames: 480, at: 0.01), for: mic)
        let muted = b.drain(upTo: .seconds(0.02))
        #expect(muted?.mix.allSatisfy { abs($0 - 0.2) < 1e-6 } == true)
    }

    @Test func aSilentSourceIsPaddedAndALateChunkIsTrimmed() {
        let b = bus()
        b.ingest(AudioTestSignals.constant(0.3, frames: 4800, at: 0), for: .minecraft)
        let block = b.drain(upTo: .seconds(0.1))
        #expect(block?.tracks[mic]?.count == 9600)
        #expect(block?.tracks[mic]?.allSatisfy { $0 == 0 } == true)
        b.ingest(AudioTestSignals.ramp(first: 0, frames: 4800, at: 0.05), for: mic)
        b.ingest(AudioTestSignals.constant(0.3, frames: 4800, at: 0.1), for: .minecraft)
        let next = b.drain(upTo: .seconds(0.2))
        #expect(next?.tracks[mic]?.first == 2400)
        #expect(next?.tracks[mic]?.count == 9600)
        #expect(next?.tracks[.minecraft]?.allSatisfy { $0 == 0.3 } == true)
    }

    @Test func aSourceStartingLateIsSilentUntilItArrives() {
        let b = bus(origin: 20)
        b.ingest(AudioTestSignals.constant(0.5, frames: 480, at: 20.01), for: mic)
        let block = b.drain(upTo: .seconds(20.02))
        let samples = block?.tracks[mic] ?? []
        #expect(samples.count == 1920)
        #expect(samples.prefix(960).allSatisfy { $0 == 0 })
        #expect(samples.suffix(960).allSatisfy { $0 == 0.5 })
    }

    @Test func aSourceAtAnotherSampleRateIsConvertedOnIngest() {
        let b = bus()
        let input = AudioTestSignals.sine(frequency: 440, amplitude: 0.5, rate: 44_100, channels: 1, frames: 4410)
        b.ingest(AudioChunk(samples: input, sampleRate: 44_100, channelCount: 1, hostTime: .zero), for: mic)
        let block = b.drain(upTo: .seconds(0.09))
        #expect(block?.frameCount == 4320)
        let ideal = AudioTestSignals.sine(frequency: 440, amplitude: 0.5, rate: 48_000, frames: 4320)
        #expect(AudioTestSignals.maxAbsDifference(block?.tracks[mic] ?? [], ideal) < 0.005)
    }

    @Test func unknownTracksAreIgnored() {
        let b = bus()
        b.ingest(AudioTestSignals.constant(1, frames: 480, at: 0), for: .source(UUID()))
        let block = b.drain(upTo: .seconds(0.01))
        #expect(block?.tracks.count == 2)
        #expect(block?.mix.allSatisfy { $0 == 0 } == true)
    }

    @Test func finishPadsEveryTrackToTheSameEnd() {
        let b = bus()
        b.ingest(AudioTestSignals.constant(0.1, frames: 480, at: 0), for: .minecraft)
        _ = b.drain(upTo: .seconds(0.01))
        let last = b.finish(at: .seconds(0.5))
        #expect(last?.startFrame == 480)
        #expect(last?.frameCount == 23_520)
        #expect(last?.tracks.values.allSatisfy { $0.count == 23_520 * 2 } == true)
    }
}
