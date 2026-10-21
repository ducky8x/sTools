import Foundation
import Testing
@testable import STDesign

/// Intended length in seconds of each bundled sound (the assignment's design targets).
private let intendedDuration: [STSound: Double] = [
    .click: 0.040, .tick: 0.025, .stamp: 0.140, .page: 0.180,
    .chime: 0.900, .recordStart: 0.160, .recordStop: 0.160,
]

private struct WAV {
    let channels: Int
    let sampleRate: Int
    let bitsPerSample: Int
    let samples: [Double]

    var duration: Double { Double(samples.count) / Double(sampleRate) }
    var peak: Double { samples.map { abs($0) }.max() ?? 0 }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 44,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        var offset = 12
        var format: (channels: Int, rate: Int, bits: Int)?
        var pcm: [Double] = []
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            guard body + size <= bytes.count else { return nil }
            if id == "fmt ", u16(body) == 1 {
                format = (u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data" {
                pcm = stride(from: body, to: body + size - 1, by: 2).map {
                    Double(Int16(bitPattern: UInt16(u16($0)))) / 32_768
                }
            }
            offset = body + size + (size & 1)
        }
        guard let format else { return nil }
        channels = format.channels
        sampleRate = format.rate
        bitsPerSample = format.bits
        samples = pcm
    }
}

private func loadWAV(_ sound: STSound) throws -> WAV {
    let url = try #require(STSoundPlayer.resourceURL(for: sound), "missing resource for \(sound)")
    return try #require(WAV(try Data(contentsOf: url)), "invalid RIFF/WAVE header for \(sound)")
}

@Test(arguments: STSound.allCases)
func bundledSoundIsAValidSoftWAV(_ sound: STSound) throws {
    let wav = try loadWAV(sound)
    #expect(wav.channels == 1)
    #expect(wav.sampleRate == 44_100)
    #expect(wav.bitsPerSample == 16)

    let intended = try #require(intendedDuration[sound])
    #expect(abs(wav.duration - intended) <= intended * 0.2, "duration \(wav.duration) vs \(intended)")

    #expect(wav.peak <= 0.45, "peak \(wav.peak)")
    #expect(wav.peak > 0.05, "sound is nearly silent")
    #expect(wav.samples.allSatisfy { abs($0) < 0.99 }, "clipping")
}

@Test(arguments: STSound.allCases)
func bundledSoundStartsAndEndsAtSilence(_ sound: STSound) throws {
    let wav = try loadWAV(sound)
    #expect(abs(try #require(wav.samples.first)) < 0.01)
    #expect(abs(try #require(wav.samples.last)) < 0.01)
}

@Test(arguments: STSound.allCases)
func bundledSoundHasNoSampleJumps(_ sound: STSound) throws {
    let wav = try loadWAV(sound)
    let largestStep = zip(wav.samples, wav.samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    #expect(largestStep < 0.15, "step \(largestStep) would be heard as a click")
}

@Test func generatorIsDeterministic() throws {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/generate-sounds.swift")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stools-sound-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    for run in ["a", "b"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", script.path, root.appendingPathComponent(run).path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "generator run \(run) failed")
    }

    for sound in STSound.allCases {
        let first = try Data(contentsOf: root.appendingPathComponent("a/\(sound.rawValue).wav"))
        let second = try Data(contentsOf: root.appendingPathComponent("b/\(sound.rawValue).wav"))
        #expect(first == second, "\(sound) differs between runs")
        #expect(!first.isEmpty)
    }
}

@Test(arguments: [
    (true, 0.7, true, true),
    (false, 0.7, true, false),
    (true, 0.0, true, false),
    (true, 0.7, false, false),
    (false, 0.0, false, false),
    (true, 1.0, true, true),
    (true, 0.01, true, true),
    (true, -0.5, true, false),
])
func shouldPlayRequiresAllThree(_ soundsEnabled: Bool, _ volume: Double, _ systemEnabled: Bool, _ expected: Bool) {
    #expect(STSoundPlayer.shouldPlay(soundsEnabled: soundsEnabled, volume: volume, systemEnabled: systemEnabled) == expected)
}

@MainActor @Test func playerStaysSilentWhenSoundsAreOff() {
    let theme = STTheme(soundsEnabled: false)
    let player = STSoundPlayer(theme: theme, systemSoundsEnabled: { true })
    for sound in STSound.allCases { player.play(sound) }
    #expect(STSound.allCases.allSatisfy { !player.isPlaying($0) })
}

@MainActor @Test func playerStaysSilentAtZeroVolume() {
    let player = STSoundPlayer(theme: STTheme(soundVolume: 0), systemSoundsEnabled: { true })
    player.play(.chime)
    #expect(!player.isPlaying(.chime))
}

@MainActor @Test func playerStaysSilentWhenSystemSoundsAreOff() {
    var asked = 0
    let player = STSoundPlayer(theme: STTheme()) { asked += 1; return false }
    player.play(.chime)
    #expect(asked == 1)
    #expect(!player.isPlaying(.chime))
}

@MainActor @Test func silentPlayerNeverPlays() {
    STSoundPlayer.silent.play(.stamp)
    #expect(!STSoundPlayer.silent.isPlaying(.stamp))
}

/// Nothing loads until a sound is asked to play, and a sound that's off never loads at all.
@MainActor @Test func soundsLoadOnlyWhenTheyFirstPlay() {
    let player = STSoundPlayer(theme: STTheme(soundsEnabled: false), systemSoundsEnabled: { true })
    #expect(player.loadedCount == 0)
    player.play(.click)
    #expect(player.loadedCount == 0, "sounds off: nothing to load")
}
