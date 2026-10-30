import Foundation
import Testing
@testable import STDesign

/// Intended length in seconds of each bundled sound (the assignment's design targets).
private let intendedDuration: [STSound: Double] = [
    .click: 0.040, .tick: 0.025, .stamp: 0.140, .page: 0.180,
    .chime: 0.900, .recordStart: 0.160, .recordStop: 0.160,
    .glideShort: 0.150, .glideMedium: 0.220, .glideLong: 0.300, .detent: 0.016,
]

/// A 16-bit PCM WAV file read back into samples. Shared with `AlarmSoundResourceTests`.
struct WAV {
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

func loadWAV(_ sound: STSound) throws -> WAV {
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

/// Whether the tests run translated by Rosetta (`sysctl.proc_translated` is 1; it is 0 natively and missing on an Intel Mac).
/// A translated test starts the x86_64 half of `swift`, which can't load the Command Line Tools' arm64-only libxcrun on this
/// Mac, so the generator is started through `arch -arm64`. It then runs natively, as it did when it made the bundled files.
/// The sToolsTests target keeps the same rule in `nativeCommand`; test targets share no code.
private let testsRunTranslated: Bool = {
    var translated: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
}()

@Test func generatorIsDeterministic() throws {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/generate-sounds.swift")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stools-sound-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    for run in ["a", "b"] {
        let process = Process()
        let generate = ["swift", script.path, root.appendingPathComponent(run).path]
        process.executableURL = URL(fileURLWithPath: testsRunTranslated ? "/usr/bin/arch" : "/usr/bin/env")
        process.arguments = testsRunTranslated ? ["-arm64", "/usr/bin/env"] + generate : generate
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "generator run \(run) failed")
    }

    // The UI sounds, then the alarms in their subfolder: the same bytes on every run, and the same bytes as the
    // bundled files, so nothing bundled is out of date with the script.
    let generated: [(path: String, bundled: URL?)] =
        STSound.allCases.map { ("\($0.rawValue).wav", $0.resourceURL) }
        + STAlarmSound.allCases.map { ("Alarms/\($0.rawValue).wav", $0.resourceURL) }
    for file in generated {
        let first = try Data(contentsOf: root.appendingPathComponent("a/\(file.path)"))
        let second = try Data(contentsOf: root.appendingPathComponent("b/\(file.path)"))
        #expect(first == second, "\(file.path) differs between runs")
        #expect(!first.isEmpty)
        let bundled = try #require(file.bundled, "\(file.path) isn't bundled")
        #expect(try Data(contentsOf: bundled) == first, "the bundled \(file.path) isn't what the script makes")
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

/// macOS's "Play user interface sound effects" as a test sets it. A class rather than a captured `var`, since the
/// player's closure is sendable.
@MainActor private final class SystemSoundsSetting {
    var isOn = true
}

/// `isAudible` is `play`'s own decision, so the sidebar can skip scheduling detents that would stay silent.
@MainActor @Test func isAudibleFollowsTheSameThreeSettings() {
    let system = SystemSoundsSetting()
    let theme = STTheme()
    let player = STSoundPlayer(theme: theme) { system.isOn }
    #expect(player.isAudible)
    system.isOn = false
    #expect(!player.isAudible)
    system.isOn = true
    theme.soundVolume = 0
    #expect(!player.isAudible)
    theme.soundVolume = 0.5
    theme.soundsEnabled = false
    #expect(!player.isAudible)
    #expect(!STSoundPlayer.silent.isAudible)
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

/// Code that plays a UI sound at its own volume (Timer Overlay's cues) finds the same bundled file the player
/// loads, without loading anything.
@Test(arguments: STSound.allCases)
func publicResourceURLIsTheBundledFile(_ sound: STSound) throws {
    let url = try #require(sound.resourceURL)
    #expect(url.lastPathComponent == "\(sound.rawValue).wav")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Sounds")
    #expect(url == STSoundPlayer.resourceURL(for: sound))
    #expect(FileManager.default.fileExists(atPath: url.path))
}
