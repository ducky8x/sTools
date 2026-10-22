import Foundation
import Testing
@testable import STDesign

/// The RMS level, in dBFS, of the loudest 100 ms of `wav`; a shorter sound counts as padded with silence, so a tiny
/// detent is measured by the little energy it has, close to how loud the ear finds it.
private func loudest100ms(_ wav: WAV) -> Double {
    let window = wav.sampleRate / 10
    let padded = wav.samples + [Double](repeating: 0, count: window)
    var running = 0.0
    var loudest = 0.0
    for (index, sample) in padded.enumerated() {
        running += sample * sample
        if index >= window { running -= padded[index - window] * padded[index - window] }
        loudest = max(loudest, running)
    }
    return 20 * log10(max(sqrt(loudest / Double(window)), 1e-12))
}

/// The largest jump between neighboring samples within `seconds` of the start or the end.
private func edgeStep(_ wav: WAV, seconds: Double, atEnd: Bool) -> Double {
    let count = Int(seconds * Double(wav.sampleRate))
    let edge = atEnd ? Array(wav.samples.suffix(count)) : Array(wav.samples.prefix(count))
    return zip(edge, edge.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

/// The sidebar's glide and detent (spec 3.4): checked by their numbers, never by ear.
@Suite("Sidebar glide and detent sounds")
struct SidebarSoundTests {
    private static let glides: [STSound] = [.glideShort, .glideMedium, .glideLong]

    @Test func theGlideGetsLongerFromShortToLong() throws {
        let durations = try Self.glides.map { try loadWAV($0).duration }
        #expect(durations == durations.sorted())
        #expect(Set(durations).count == 3)
        #expect((0.1...0.35).contains(try #require(durations.first)))
        #expect((0.1...0.35).contains(try #require(durations.last)))
    }

    /// Each glide is about as loud as `page`, the sound it took over in the sidebar, and a farther one isn't quieter.
    @Test func theGlidesSitByThePageSound() throws {
        let page = loudest100ms(try loadWAV(.page))
        let levels = try Self.glides.map { loudest100ms(try loadWAV($0)) }
        for (glide, level) in zip(Self.glides, levels) {
            #expect(abs(level - page) <= 3, "\(glide) \(level) dBFS vs page \(page) dBFS")
        }
        #expect(levels[0] <= levels[1] + 0.5 && levels[0] < levels[2], "levels \(levels)")
    }

    @Test func theDetentIsATinyTap() throws {
        let wav = try loadWAV(.detent)
        #expect((0.010...0.025).contains(wav.duration), "duration \(wav.duration)")
        #expect(wav.peak <= 0.25 && wav.peak > 0.05, "peak \(wav.peak)")
    }

    /// Quiet: under `tick`, the quietest of the set, by no more than 6 dB, since several can come in a row.
    @Test func theDetentSitsJustUnderTheTick() throws {
        let tick = loudest100ms(try loadWAV(.tick))
        let detent = loudest100ms(try loadWAV(.detent))
        #expect(detent <= tick && detent >= tick - 6, "detent \(detent) dBFS vs tick \(tick) dBFS")
    }

    /// No click at either end: both ends are silent and the first and last two milliseconds move gently.
    @Test(arguments: [STSound.glideShort, .glideMedium, .glideLong, .detent])
    func startsAndEndsWithoutAClick(_ sound: STSound) throws {
        let wav = try loadWAV(sound)
        #expect(try #require(wav.samples.first) == 0)
        #expect(try #require(wav.samples.last) == 0)
        #expect(edgeStep(wav, seconds: 0.002, atEnd: false) < 0.06, "start step")
        #expect(edgeStep(wav, seconds: 0.002, atEnd: true) < 0.01, "end step")
        #expect(wav.samples.allSatisfy { abs($0) < 0.99 }, "clipping")
    }
}
