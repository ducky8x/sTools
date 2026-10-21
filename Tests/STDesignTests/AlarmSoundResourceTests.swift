import Foundation
import Testing
@testable import STDesign

/// Each alarm's length in seconds, as the generator makes it.
private let intendedDuration: [STAlarmSound: Double] = [.ember: 1.6, .lantern: 1.4, .toll: 1.9, .knock: 1.2]

private func loadAlarm(_ sound: STAlarmSound) throws -> WAV {
    let url = try #require(sound.resourceURL, "missing resource for \(sound)")
    return try #require(WAV(try Data(contentsOf: url)), "invalid RIFF/WAVE header for \(sound)")
}

private func dBFS(_ amplitude: Double) -> Double { 20 * log10(max(amplitude, 1e-12)) }

/// The RMS level of the whole sound, in dBFS.
private func level(_ samples: [Double]) -> Double {
    dBFS(sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(max(samples.count, 1))))
}

/// The RMS level of the loudest whole stretch of `seconds`, in dBFS.
private func loudestLevel(_ wav: WAV, seconds: Double) -> Double {
    let window = Int(Double(wav.sampleRate) * seconds)
    var running = 0.0
    var loudest = 0.0
    for (index, sample) in wav.samples.enumerated() {
        running += sample * sample
        if index >= window { running -= wav.samples[index - window] * wav.samples[index - window] }
        if index >= window - 1 { loudest = max(loudest, running) }
    }
    return dBFS(sqrt(loudest / Double(window)))
}

private func largestStep<C: Collection>(_ samples: C) -> Double where C.Element == Double {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

/// sTools' own alarms (spec 5.6.6): checked by their numbers, never by ear.
@Suite("sTools alarm sounds")
struct AlarmSoundResourceTests {
    @Test func thereAreAtLeastThreeEachWithItsOwnName() {
        #expect(STAlarmSound.allCases.count >= 3)
        let titles = STAlarmSound.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(titles).count == titles.count)
        #expect(Set(STAlarmSound.allCases.map(\.rawValue)).count == STAlarmSound.allCases.count)
    }

    @Test(arguments: STAlarmSound.allCases)
    func eachIsBundledInTheAlarmsFolderBesideTheUISounds(_ sound: STAlarmSound) throws {
        let url = try #require(sound.resourceURL)
        #expect(url.lastPathComponent == "\(sound.rawValue).wav")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Alarms")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent()
            == STSound.chime.resourceURL?.deletingLastPathComponent())
    }

    @Test(arguments: STAlarmSound.allCases)
    func eachIsAnAlarmLengthWAVInTheUISoundsFormat(_ sound: STAlarmSound) throws {
        let wav = try loadAlarm(sound)
        #expect(wav.channels == 1)
        #expect(wav.sampleRate == 44_100)
        #expect(wav.bitsPerSample == 16)
        #expect((1.0...2.0).contains(wav.duration), "duration \(wav.duration)")
        let intended = try #require(intendedDuration[sound])
        #expect(abs(wav.duration - intended) < 0.001, "duration \(wav.duration) vs \(intended)")
    }

    /// Loud enough for an alarm, with the UI set's headroom, and never clipped. The generator sets each peak so
    /// the four sound about equally loud (its comment has the measure); these bands catch a level gone wrong.
    @Test(arguments: STAlarmSound.allCases)
    func eachIsAtAnAlarmsLevelWithoutClipping(_ sound: STAlarmSound) throws {
        let wav = try loadAlarm(sound)
        #expect(wav.peak <= 0.45, "peak \(wav.peak)")
        #expect(wav.peak >= 0.1, "peak \(wav.peak): too quiet for an alarm")
        #expect(wav.samples.allSatisfy { abs($0) < 0.99 }, "clipping")
        #expect((-32.0 ... -18.0).contains(level(wav.samples)), "RMS \(level(wav.samples)) dBFS")
        let loudest = loudestLevel(wav, seconds: 0.1)
        #expect((-26.0 ... -12.0).contains(loudest), "loudest 100 ms \(loudest) dBFS")
    }

    @Test(arguments: STAlarmSound.allCases)
    func eachStartsAndEndsWithoutAClick(_ sound: STAlarmSound) throws {
        let wav = try loadAlarm(sound)
        let fiveMilliseconds = wav.sampleRate / 200
        #expect(abs(try #require(wav.samples.first)) < 0.001)
        #expect(abs(try #require(wav.samples.last)) < 0.001)
        #expect(largestStep(wav.samples.prefix(fiveMilliseconds)) < 0.05, "it eases in rather than starting at once")
        #expect(wav.samples.suffix(fiveMilliseconds).allSatisfy { abs($0) < 0.002 }, "it has faded out by its end")
        let step = largestStep(wav.samples)
        #expect(step < 0.15, "step \(step) would be heard as a click")
    }

    @Test func noTwoAreTheSameSound() throws {
        let files = try STAlarmSound.allCases.map { try Data(contentsOf: try #require($0.resourceURL)) }
        #expect(Set(files).count == files.count)
    }

    /// Nothing loads an alarm ahead of time: the UI player loads nothing until a UI sound plays, and an alarm's
    /// file is none of the UI sounds' files, so the UI player can never load one. Timer Overlay reads an alarm
    /// only when it plays.
    @MainActor @Test func nothingLoadsTheAlarmsAheadOfTime() {
        let player = STSoundPlayer(theme: STTheme(), systemSoundsEnabled: { false })
        #expect(player.loadedCount == 0)
        let uiFiles = Set(STSound.allCases.compactMap(\.resourceURL))
        #expect(STAlarmSound.allCases.compactMap(\.resourceURL).allSatisfy { !uiFiles.contains($0) })
    }
}
