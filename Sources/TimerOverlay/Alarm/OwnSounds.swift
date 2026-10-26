import AVFoundation
import Foundation
import STPlatform

/// Why one of the owner's sound files couldn't be added or removed. The messages are placeholder wording for M9.
public enum OwnSoundsError: Error, Equatable, LocalizedError {
    /// The file doesn't decode as sound, so no copy was kept.
    case notASound
    /// The file couldn't be copied into `Sounds/`.
    case copyFailed(String)
    /// The sound isn't one of the owner's files in `Sounds/`.
    case notAnOwnSound
    /// The file couldn't be deleted.
    case removeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notASound: "sTools can\u{2019}t play that file. Choose an MP3, WAV or other sound."
        case .copyFailed: "sTools couldn\u{2019}t copy that file into its Sounds folder. Check that your disk isn\u{2019}t full, then try again."
        case .notAnOwnSound: "That sound isn't one of your files."
        case .removeFailed: "sTools couldn't remove that file."
        }
    }
}

/// The owner's own alarm files (spec 5.6.6, 5.6.10): copies kept in `Sounds/` in the settings folder, which
/// settings export, import and Reset sTools carry. Each is an `AlarmSound` whose ID is `file:<file name>`.
///
/// The folder is flat, and every name in it is a plain, visible file name (`SettingsLayout.isValidSoundFileName`),
/// so export and import carry each one as it is.
public struct OwnSounds: Sendable {
    /// `Sounds/` in the settings folder.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Sounds/` in `settingsDirectory`.
    public init(settingsDirectory: URL) {
        self.init(directory: settingsDirectory.appending(path: SettingsLayout.soundsFolderName, directoryHint: .isDirectory))
    }

    /// `Sounds/` in the app's settings folder.
    @MainActor public static var inSettingsFolder: OwnSounds {
        OwnSounds(settingsDirectory: SettingsStore.defaultDirectory())
    }

    /// The owner's files, sorted by title: the plain, visible files directly inside the folder.
    public func sounds() -> [AlarmSound] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return contents
            .map(\.lastPathComponent)
            .filter { SettingsLayout.isValidSoundFileName($0) }
            .map { AlarmSound.ownFile(named: $0, in: directory) }
            .filter { AlarmSound.isRegularFile($0.url) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Copies `file` into the folder under a name not yet taken: its own name (or `preferredName`) made plain
    /// and visible, then `Name 2.ext`, `Name 3.ext`, and so on. The copy is kept only if it decodes as sound.
    /// - Returns: the added sound; its `id` is what the settings store.
    @discardableResult
    public func add(_ file: URL, preferredName: String? = nil) throws -> AlarmSound {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw OwnSoundsError.copyFailed(error.localizedDescription)
        }
        let name = Self.availableName(for: preferredName ?? file.lastPathComponent, in: directory)
        let sound = AlarmSound.ownFile(named: name, in: directory)
        do {
            try fileManager.copyItem(at: file, to: sound.url)
        } catch {
            throw OwnSoundsError.copyFailed(error.localizedDescription)
        }
        guard Self.decodes(sound.url) else {
            try? fileManager.removeItem(at: sound.url)
            throw OwnSoundsError.notASound
        }
        return sound
    }

    /// Deletes one of the owner's files. One that's already gone is fine.
    public func remove(_ sound: AlarmSound) throws {
        guard sound.source == .file, SettingsLayout.isValidSoundFileName(sound.name),
              sound.url.standardizedFileURL
                == AlarmSound.ownFile(named: sound.name, in: directory).url.standardizedFileURL
        else { throw OwnSoundsError.notAnOwnSound }
        guard FileManager.default.fileExists(atPath: sound.url.path) else { return }
        do {
            try FileManager.default.removeItem(at: sound.url)
        } catch {
            throw OwnSoundsError.removeFailed(error.localizedDescription)
        }
    }

    // MARK: Names

    /// The longest name the folder gets, in UTF-8 bytes: well short of the file system's 255, with room for a number.
    static let longestName = 200
    /// An "extension" longer than this is part of the name.
    private static let longestExtension = 16

    /// `name` made plain and visible, then numbered until no file in `directory` has it. The file system decides
    /// what "has it" means, so on a case-insensitive disk `BELL.wav` is taken by `Bell.wav`.
    static func availableName(for name: String, in directory: URL) -> String {
        let (stem, pathExtension) = plainParts(of: name)
        var candidate = joined(stem, pathExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) {
            candidate = joined("\(stem) \(number)", pathExtension)
            number += 1
        }
        return candidate
    }

    /// The name's stem and extension without what a sound's file name can't have: slashes, backslashes and control
    /// characters become `-`, and leading dots (a hidden file) and surrounding spaces go. An empty stem becomes
    /// "Sound", and a long one is cut to fit `longestName`.
    static func plainParts(of name: String) -> (stem: String, pathExtension: String) {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            scalar == "/" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) ? "-" : scalar
        }))
        while let first = cleaned.first, first == "." || first.isWhitespace { cleaned.removeFirst() }
        var pathExtension = (cleaned as NSString).pathExtension
        var stem = (cleaned as NSString).deletingPathExtension
        if pathExtension.utf8.count > longestExtension || pathExtension.contains(" ") {
            pathExtension = ""
            stem = cleaned
        }
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "Sound" }
        while joined(stem, pathExtension).utf8.count > longestName, stem.count > 1 { stem.removeLast() }
        return (stem, pathExtension)
    }

    private static func joined(_ stem: String, _ pathExtension: String) -> String {
        pathExtension.isEmpty ? stem : "\(stem).\(pathExtension)"
    }

    // MARK: Checking

    /// Whether the file opens as sound and its first second decodes: what "checked to play" means (spec 5.6.6).
    /// It reads the file; nothing plays.
    static func decodes(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return false }
        let format = file.processingFormat
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(min(file.length, AVAudioFramePosition(format.sampleRate))))
        else { return false }
        do {
            try file.read(into: buffer)
        } catch {
            return false
        }
        return buffer.frameLength > 0
    }
}

extension AlarmSound {
    /// Everything the alarm picker lists, in its order: the macOS sounds this Mac has, sTools' alarms, then the
    /// owner's files.
    public static func all(own: OwnSounds, macOSDirectory: URL = systemSoundsDirectory) -> [AlarmSound] {
        macOSSounds(in: macOSDirectory) + sToolsSounds + own.sounds()
    }

    /// Finds the sound a saved ID names, looking for `file:` IDs in the owner's folder (see
    /// `resolve(_:soundsDirectory:macOSDirectory:)`).
    public static func resolve(_ id: String, own: OwnSounds, macOSDirectory: URL = systemSoundsDirectory) -> Resolution {
        resolve(id, soundsDirectory: own.directory, macOSDirectory: macOSDirectory)
    }
}
