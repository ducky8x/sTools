import Foundation
import STDesign
import STPlatform
import Testing
@testable import TimerOverlay

/// A settings folder and a folder of files to add, removed when the test ends.
private final class Sandbox {
    let root: URL
    let settings: URL
    let picked: URL
    let own: OwnSounds

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "sTools-own-sounds-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        settings = root.appending(path: "settings", directoryHint: .isDirectory)
        picked = root.appending(path: "picked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        own = OwnSounds(settingsDirectory: settings)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A real sound file to add, named `name`. Reading it never plays it.
    func sound(_ name: String, from alarm: STAlarmSound = .knock) throws -> URL {
        let url = picked.appending(path: name)
        try FileManager.default.copyItem(at: try #require(alarm.resourceURL), to: url)
        return url
    }

    func text(_ name: String, _ text: String = "not a sound") throws -> URL {
        let url = picked.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func filesInSounds() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: own.directory.path)) ?? []).sorted()
    }
}

@Suite("Own sounds")
struct OwnSoundsTests {
    @Test func theFolderIsSoundsInTheSettingsFolder() throws {
        let box = try Sandbox()
        #expect(box.own.directory.path == box.settings.appending(path: "Sounds").path)
        #expect(box.own.directory.lastPathComponent == SettingsLayout.soundsFolderName)
        #expect(OwnSounds(directory: box.picked).directory == box.picked)
    }

    // MARK: Adding

    @Test func addingCopiesTheFileInUnderItsOwnName() throws {
        let box = try Sandbox()
        let source = try box.sound("My Alarm.wav", from: .ember)

        let sound = try box.own.add(source)

        #expect(sound.id == "file:My Alarm.wav")
        #expect(sound.source == .file)
        #expect(sound.title == "My Alarm")
        #expect(box.filesInSounds() == ["My Alarm.wav"])
        #expect(try Data(contentsOf: sound.url) == Data(contentsOf: source))
        #expect(FileManager.default.fileExists(atPath: source.path), "the picked file stays where it was")
        #expect(SettingsLayout.isValidSoundFileName(sound.name), "export and import carry it")
    }

    @Test func addingCreatesTheFolder() throws {
        let box = try Sandbox()
        #expect(!FileManager.default.fileExists(atPath: box.own.directory.path))
        _ = try box.own.add(try box.sound("a.wav"))
        #expect(box.filesInSounds() == ["a.wav"])
    }

    @Test func aTakenNameGetsTheNextNumber() throws {
        let box = try Sandbox()
        let source = try box.sound("Bell.wav")
        let names = try (1...3).map { _ in try box.own.add(source).name }
        #expect(names == ["Bell.wav", "Bell 2.wav", "Bell 3.wav"])
        #expect(box.filesInSounds() == ["Bell 2.wav", "Bell 3.wav", "Bell.wav"])
    }

    @Test func aNameTakenInAnotherCaseIsntOverwritten() throws {
        let box = try Sandbox()
        let first = try box.own.add(try box.sound("Bell.wav"))
        let before = try Data(contentsOf: first.url)
        _ = try box.own.add(try box.sound("other.wav", from: .toll), preferredName: "BELL.wav")
        #expect(box.filesInSounds().count == 2)
        #expect(try Data(contentsOf: first.url) == before)
    }

    @Test(arguments: [(".secret.wav", "secret.wav"), ("back\\slash.wav", "back-slash.wav"), ("  spaced  .wav", "spaced.wav"),
                      ("...wav", "wav"), (". .wav", "wav"), ("....", "Sound")])
    func anOddNameIsMadePlainAndVisible(_ picked: String, _ kept: String) throws {
        let box = try Sandbox()
        let sound = try box.own.add(try box.sound(picked))
        #expect(sound.name == kept)
        #expect(SettingsLayout.isValidSoundFileName(sound.name))
        #expect(box.filesInSounds() == [kept])
    }

    @Test func aVeryLongNameIsShortenedForTheFileSystem() throws {
        let box = try Sandbox()
        let long = String(repeating: "é", count: 200) + ".wav"
        let picked = box.picked.appending(path: "long.wav")
        try FileManager.default.copyItem(at: try #require(STAlarmSound.knock.resourceURL), to: picked)
        let sound = try box.own.add(picked, preferredName: long)
        #expect(sound.name.utf8.count <= 255)
        #expect(sound.name.hasSuffix(".wav"))
        #expect(SettingsLayout.isValidSoundFileName(sound.name))
    }

    @Test(arguments: ["fake.mp3", "fake.wav", "notes.txt"])
    func aFileThatDoesntDecodeIsNotKept(_ name: String) throws {
        let box = try Sandbox()
        #expect(throws: OwnSoundsError.notASound) { try box.own.add(try box.text(name)) }
        #expect(box.filesInSounds().isEmpty)
    }

    @Test func anEmptyWAVIsNotKept() throws {
        let box = try Sandbox()
        // A valid header with no audio in it.
        var header = Data("RIFF".utf8)
        header.append(contentsOf: [36, 0, 0, 0])
        header.append(Data("WAVEfmt ".utf8))
        header.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x44, 0xAC, 0, 0, 0x88, 0x58, 1, 0, 2, 0, 16, 0])
        header.append(Data("data".utf8))
        header.append(contentsOf: [0, 0, 0, 0])
        let url = box.picked.appending(path: "empty.wav")
        try header.write(to: url)
        #expect(throws: OwnSoundsError.notASound) { try box.own.add(url) }
        #expect(box.filesInSounds().isEmpty)
    }

    @Test func aMissingFileIsNotAdded() throws {
        let box = try Sandbox()
        #expect(throws: OwnSoundsError.self) { try box.own.add(box.picked.appending(path: "gone.wav")) }
        #expect(box.filesInSounds().isEmpty)
    }

    @Test func anAddedSoundResolvesAsTheSavedSound() throws {
        let box = try Sandbox()
        let sound = try box.own.add(try box.sound("Door.wav"))
        let resolution = AlarmSound.resolve(sound.id, soundsDirectory: box.own.directory)
        #expect(resolution.sound == sound)
        #expect(!resolution.isMissing)
        #expect(sound.length != nil)
    }

    // MARK: Listing

    @Test func theListHoldsOnlyPlainVisibleFilesSortedByTitle() throws {
        let box = try Sandbox()
        _ = try box.own.add(try box.sound("b.wav"))
        _ = try box.own.add(try box.sound("A.wav"))
        _ = try box.own.add(try box.sound("c.wav"))
        try Data("x".utf8).write(to: box.own.directory.appending(path: ".DS_Store"))
        try FileManager.default.createDirectory(at: box.own.directory.appending(path: "folder"), withIntermediateDirectories: true)

        let sounds = box.own.sounds()

        #expect(sounds.map(\.title) == ["A", "b", "c"])
        #expect(sounds.allSatisfy { $0.source == .file })
    }

    @Test func noFolderMeansNoSounds() throws {
        let box = try Sandbox()
        #expect(box.own.sounds().isEmpty)
    }

    @Test func thePickerListsMacOSThenSToolsThenTheOwnersFiles() throws {
        let box = try Sandbox()
        let mine = try box.own.add(try box.sound("Mine.wav"))

        let all = AlarmSound.all(own: box.own)

        #expect(all == AlarmSound.macOSSounds() + AlarmSound.sToolsSounds + [mine])
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(AlarmSound.resolve(mine.id, own: box.own).sound == mine)
    }

    // MARK: Removing

    @Test func removingDeletesTheFile() throws {
        let box = try Sandbox()
        let kept = try box.own.add(try box.sound("Keep.wav"))
        let removed = try box.own.add(try box.sound("Remove.wav"))

        try box.own.remove(removed)

        #expect(box.filesInSounds() == ["Keep.wav"])
        #expect(box.own.sounds() == [kept])
    }

    @Test func removingAFileThatsAlreadyGoneIsFine() throws {
        let box = try Sandbox()
        let sound = try box.own.add(try box.sound("Gone.wav"))
        try FileManager.default.removeItem(at: sound.url)
        try box.own.remove(sound)
        #expect(box.filesInSounds().isEmpty)
    }

    @Test func onlyTheOwnersFilesCanBeRemoved() throws {
        let box = try Sandbox()
        let elsewhere = AlarmSound.ownFile(named: "x.wav", in: box.picked)
        _ = try box.sound("x.wav")
        let macOS = try #require(AlarmSound.sToolsSounds.first)

        #expect(throws: OwnSoundsError.notAnOwnSound) { try box.own.remove(elsewhere) }
        #expect(throws: OwnSoundsError.notAnOwnSound) { try box.own.remove(macOS) }
        #expect(FileManager.default.fileExists(atPath: box.picked.appending(path: "x.wav").path))
        #expect(FileManager.default.fileExists(atPath: macOS.url.path))
    }
}
