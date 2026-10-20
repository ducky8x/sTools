import CoreMedia
import Foundation
import Testing
@testable import ScreenRecording

@Suite struct AudioTimelineTests {
    private let tenMs = 480

    @Test func contiguousChunksAreAppendedUntouched() {
        var t = AudioTimeline(origin: .seconds(100))
        let a = t.place(AudioTestSignals.constant(0.1, frames: tenMs, at: 100))
        let b = t.place(AudioTestSignals.constant(0.1, frames: tenMs, at: 100.01))
        #expect(a.startFrame == 0 && b.startFrame == 480)
        #expect(a.paddedFrames == 0 && b.paddedFrames == 0 && b.trimmedFrames == 0)
        #expect(b.frameCount == 480)
        #expect(t.endFrame == 960)
    }

    @Test func timestampJitterWithinToleranceIsIgnored() {
        var t = AudioTimeline(origin: .zero)
        _ = t.place(AudioTestSignals.constant(0.1, frames: 480, at: 0))
        let early = t.place(AudioTestSignals.constant(0.1, frames: 480, at: 0.01 - 0.004))
        let late = t.place(AudioTestSignals.constant(0.1, frames: 480, at: 0.02 + 0.004))
        #expect(early.paddedFrames == 0 && early.trimmedFrames == 0)
        #expect(late.paddedFrames == 0 && late.trimmedFrames == 0)
        #expect(t.endFrame == 1440)
    }

    @Test func aGapIsFilledWithSilence() {
        var t = AudioTimeline(origin: .zero)
        _ = t.place(AudioTestSignals.constant(0.5, frames: 4800, at: 0))
        let p = t.place(AudioTestSignals.constant(0.5, frames: 480, at: 0.3))
        #expect(p.paddedFrames == 9600)
        #expect(p.startFrame == 4800)
        #expect(p.frameCount == 9600 + 480)
        #expect(p.samples.prefix(9600 * 2).allSatisfy { $0 == 0 })
        #expect(p.samples.suffix(480 * 2).allSatisfy { $0 == 0.5 })
        #expect(t.endFrame == 4800 + 9600 + 480)
        #expect(t.totalPaddedFrames == 9600)
    }

    @Test func anOverlapIsTrimmedFromTheChunkHead() {
        var t = AudioTimeline(origin: .zero)
        _ = t.place(AudioTestSignals.ramp(first: 0, frames: 4800, at: 0))
        let p = t.place(AudioTestSignals.ramp(first: 1000, frames: 4800, at: 0.05))
        #expect(p.trimmedFrames == 2400)
        #expect(p.frameCount == 2400)
        #expect(p.samples.first == 3400)
        #expect(p.startFrame == 4800)
        #expect(t.endFrame == 7200)
        #expect(t.totalTrimmedFrames == 2400)
    }

    @Test func aChunkFullyInThePastIsDropped() {
        var t = AudioTimeline(origin: .zero)
        _ = t.place(AudioTestSignals.constant(0.2, frames: 48_000, at: 0))
        let p = t.place(AudioTestSignals.constant(0.2, frames: 480, at: 0.2))
        #expect(p.samples.isEmpty)
        #expect(p.trimmedFrames == 480)
        #expect(t.endFrame == 48_000)
    }

    @Test func aSourceThatStartsLateGetsLeadingSilence() {
        var t = AudioTimeline(origin: .seconds(10))
        let p = t.place(AudioTestSignals.constant(0.3, frames: 480, at: 10.5))
        #expect(p.startFrame == 0)
        #expect(p.paddedFrames == 24_000)
        #expect(p.samples.prefix(24_000 * 2).allSatisfy { $0 == 0 })
    }

    @Test func samplesBeforeTheOriginAreCut() {
        var t = AudioTimeline(origin: .seconds(10))
        let p = t.place(AudioTestSignals.ramp(first: 0, frames: 4800, at: 9.9))
        #expect(p.trimmedFrames == 4800)
        let q = t.place(AudioTestSignals.ramp(first: 0, frames: 4800, at: 9.95))
        #expect(q.trimmedFrames == 2400)
        #expect(q.samples.first == 2400)
    }

    @Test func aDriftingSourceClockIsCorrectedWithinTolerance() {
        var t = AudioTimeline(origin: .zero)
        var stamp = 0.0
        for _ in 0..<200 {
            _ = t.place(AudioTestSignals.constant(0.1, frames: 480, at: stamp))
            stamp += 0.0101
        }
        let expectedEnd = Int64(((stamp - 0.0101 + 0.01) * 48_000).rounded())
        #expect(abs(t.endFrame - expectedEnd) <= 480)
        #expect(t.totalPaddedFrames > 0)
    }

    @Test func padSilenceExtendsTheTrackOnlyForward() {
        var t = AudioTimeline(origin: .zero)
        #expect(t.padSilence(to: 100).count == 200)
        #expect(t.padSilence(to: 50).isEmpty)
        #expect(t.endFrame == 100)
    }

    @Test func frameAtConvertsHostTime() {
        let t = AudioTimeline(origin: .seconds(5))
        #expect(t.frame(at: .seconds(6.5)) == 72_000)
    }
}
