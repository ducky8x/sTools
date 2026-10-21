import Foundation
import STDesign
import Testing
@testable import TimerOverlay

/// A temporary folder holding a stand-in for `/System/Library/Sounds` and one for `Sounds/`, removed when the
/// test ends.
private final class Sandbox {
    let root: URL
    let macOS: URL
    let sounds: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "sTools-alarm-sound-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        macOS = root.appending(path: "System Sounds", directoryHint: .isDirectory)
        sounds = root.appending(path: "Sounds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Copies a real sound file to `relative` under `directory`. Reading sounds never plays them.
    func copy(_ source: URL, to relative: String, in directory: URL) throws {
        let destination = directory.appending(path: relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func resolve(_ id: String) -> AlarmSound.Resolution {
        AlarmSound.resolve(id, soundsDirectory: sounds, macOSDirectory: macOS)
    }
}

private let systemPing = URL(filePath: "/System/Library/Sounds/Ping.aiff")
private let systemGlass = URL(filePath: "/System/Library/Sounds/Glass.aiff")

private func bundled(_ sound: STAlarmSound) throws -> URL {
    try #require(sound.resourceURL)
}

@Suite("Alarm sounds")
struct AlarmSoundTests {
    // MARK: IDs

    @Test func idsAreTheSourceThenTheName() {
        #expect(AlarmSound.id(.macOS, "Ping") == "macOS:Ping")
        #expect(AlarmSound.id(.sTools, "ember") == "sTools:ember")
        #expect(AlarmSound.id(.file, "Bell 2.wav") == "file:Bell 2.wav")
        #expect(AlarmSound.fallbackID == TimerOverlaySettings.defaultSoundID)
    }

    @Test(arguments: [
        ("macOS:Ping", AlarmSound.Source.macOS, "Ping"),
        ("sTools:toll", .sTools, "toll"),
        ("file:Alarm.mp3", .file, "Alarm.mp3"),
        ("file:a:b.m4a", .file, "a:b.m4a"),
    ])
    func parsingSplitsAtTheFirstColon(_ id: String, _ source: AlarmSound.Source, _ name: String) throws {
        let parsed = try #require(AlarmSound.parse(id))
        #expect(parsed.source == source)
        #expect(parsed.name == name)
        #expect(AlarmSound.id(parsed.source, parsed.name) == id)
    }

    @Test(arguments: ["Ping", "", "macOS:", "windows:Ding", "MACOS:Ping", ":Ping"])
    func parsingRefusesWhatNamesNoSound(_ id: String) {
        #expect(AlarmSound.parse(id) == nil)
    }

    // MARK: The list

    @Test func theMacOSSoundsAreTheSpecsTwelveInItsOrder() {
        #expect(AlarmSound.macOSNames == [
            "Glass", "Hero", "Ping", "Submarine", "Sosumi", "Funk", "Bottle", "Blow", "Morse", "Tink", "Frog", "Pop",
        ])
        #expect(AlarmSound.systemSoundsDirectory.path == "/System/Library/Sounds")
    }

    @Test func aMacOSSoundThisMacLacksIsLeftOut() throws {
        let box = try Sandbox()
        try box.copy(systemPing, to: "Ping.aiff", in: box.macOS)
        try box.copy(systemGlass, to: "Glass.aiff", in: box.macOS)
        try box.copy(systemPing, to: "Basso.aiff", in: box.macOS)

        let sounds = AlarmSound.macOSSounds(in: box.macOS)

        #expect(sounds.map(\.id) == ["macOS:Glass", "macOS:Ping"], "in the spec's order; Basso isn't one of the 12")
        #expect(sounds.map(\.title) == ["Glass", "Ping"])
        #expect(sounds.allSatisfy { $0.source == .macOS })
        #expect(sounds.last?.url.standardizedFileURL == box.macOS.appending(path: "Ping.aiff").standardizedFileURL)
    }

    /// The real folder, read only: this Mac has all twelve, and Ping is the length the spec measured.
    @Test func thisMacHasAllTwelve() throws {
        let sounds = AlarmSound.macOSSounds()
        #expect(sounds.count == 12)
        let ping = try #require(sounds.first { $0.name == "Ping" })
        let length = try #require(ping.length)
        #expect(abs(length - 1.50) < 0.01, "Ping lasts \(length) s")
    }

    @Test func sToolsAlarmsComeFromTheBundleWithTheirTitles() {
        let sounds = AlarmSound.sToolsSounds
        #expect(sounds.map(\.id) == STAlarmSound.allCases.map { "sTools:\($0.rawValue)" })
        #expect(sounds.map(\.title) == STAlarmSound.allCases.map(\.title))
        #expect(sounds.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(sounds.count >= 3)
    }

    @Test(arguments: [("Bell 2.wav", "Bell 2"), ("Alarm.mp3", "Alarm"), ("no extension", "no extension"),
                      ("two.dots.m4a", "two.dots")])
    func anOwnFileIsTitledByItsNameWithoutTheExtension(_ name: String, _ title: String) {
        #expect(AlarmSound.ownFile(named: name, in: URL(filePath: "/tmp/Sounds")).title == title)
    }

    // MARK: Lengths

    @Test(arguments: STAlarmSound.allCases)
    func theLengthComesFromTheFile(_ alarm: STAlarmSound) throws {
        let sound = try #require(AlarmSound.sToolsSounds.first { $0.name == alarm.rawValue })
        let length = try #require(sound.length)
        #expect((1.0...2.0).contains(length))
    }

    @Test func aFileThatIsntSoundHasNoLength() throws {
        let box = try Sandbox()
        try Data("not a sound".utf8).write(to: box.sounds.appending(path: "fake.mp3"))
        #expect(AlarmSound.length(of: box.sounds.appending(path: "fake.mp3")) == nil)
        #expect(AlarmSound.length(of: box.sounds.appending(path: "missing.wav")) == nil)
    }

    // MARK: Resolving a saved ID (decision 12)

    @Test func theSavedSoundPlaysWhenItsThere() throws {
        let box = try Sandbox()
        try box.copy(systemPing, to: "Ping.aiff", in: box.macOS)
        try box.copy(systemGlass, to: "Glass.aiff", in: box.macOS)
        try box.copy(try bundled(.knock), to: "Door.wav", in: box.sounds)

        #expect(box.resolve("macOS:Glass").sound.id == "macOS:Glass")
        #expect(box.resolve("macOS:Ping").sound.id == "macOS:Ping")
        #expect(box.resolve("sTools:toll").sound.id == "sTools:toll")
        let file = box.resolve("file:Door.wav")
        #expect(file.sound.id == "file:Door.wav")
        #expect(file.sound.title == "Door")
        #expect(file.sound.url.standardizedFileURL == box.sounds.appending(path: "Door.wav").standardizedFileURL)
        #expect([box.resolve("macOS:Glass"), box.resolve("sTools:toll"), file].allSatisfy { !$0.isMissing })
    }

    @Test(arguments: ["file:gone.mp3", "macOS:Hero", "sTools:nope", "file:../escape.wav", "file:.hidden.wav",
                      "file:sub/dir.wav", "garbage", ""])
    func aMissingSoundFallsBackToPingAndSaysSo(_ id: String) throws {
        let box = try Sandbox()
        try box.copy(systemPing, to: "Ping.aiff", in: box.macOS)
        // Real files that a safe resolver still never reaches: hidden, in a subfolder, or outside `Sounds/`.
        try box.copy(try bundled(.knock), to: ".hidden.wav", in: box.sounds)
        try box.copy(try bundled(.knock), to: "sub/dir.wav", in: box.sounds)
        try box.copy(try bundled(.knock), to: "escape.wav", in: box.root)

        let resolution = box.resolve(id)

        #expect(resolution.sound.id == "macOS:Ping")
        #expect(resolution.isMissing)
    }

    @Test func aMacWithoutPingFallsBackToSToolsFirstAlarm() throws {
        let box = try Sandbox()
        let resolution = box.resolve("file:gone.mp3")
        #expect(resolution.sound.id == AlarmSound.sToolsSounds.first?.id)
        #expect(resolution.isMissing)
        #expect(box.resolve("macOS:Ping").isMissing)
    }

    @Test func theDefaultSoundIsPingOnThisMac() throws {
        let box = try Sandbox()
        let resolution = AlarmSound.resolve(TimerOverlaySettings.defaultValue.soundID, soundsDirectory: box.sounds)
        #expect(resolution.sound.id == "macOS:Ping")
        #expect(!resolution.isMissing)
        #expect(resolution.sound.url.path == "/System/Library/Sounds/Ping.aiff")
    }
}
