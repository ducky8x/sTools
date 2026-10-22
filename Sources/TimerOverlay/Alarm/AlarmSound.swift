import AVFoundation
import Foundation
import STDesign
import STPlatform

/// One sound the alarm can ring (spec 5.6.6): a macOS sound, one of sTools' alarms, or one of the owner's own
/// files in `Sounds/`. Its ID is what the settings store in `soundID`: `macOS:<name>`, `sTools:<name>` or
/// `file:<file name>`.
///
/// Nothing here plays or loads a sound: listing reads folder names, and `length` reads only a file's header.
public struct AlarmSound: Hashable, Sendable, Identifiable {
    public enum Source: String, CaseIterable, Sendable {
        /// One of the 12 sounds in `/System/Library/Sounds`.
        case macOS
        /// One of sTools' own alarms (`STAlarmSound`).
        case sTools
        /// One of the owner's files in `Sounds/` in the settings folder.
        case file
    }

    public let source: Source
    /// The name inside its source: `Ping`, `ember`, `Bell 2.wav`.
    public let name: String
    /// What the alarm picker shows: `Ping`, `Ember`, `Bell 2`. Placeholder wording for M9.
    public let title: String
    /// The file that plays.
    public let url: URL

    public var id: String { Self.id(source, name) }

    public init(source: Source, name: String, title: String, url: URL) {
        self.source = source
        self.name = name
        self.title = title
        self.url = url
    }
}

// MARK: - IDs

extension AlarmSound {
    /// What a missing sound falls back to: Ping, the owner's saved sound (decision 12).
    public static let fallbackID = TimerOverlaySettings.defaultSoundID

    public static func id(_ source: Source, _ name: String) -> String { "\(source.rawValue):\(name)" }

    /// An ID's source and name, split at the first colon, or nil when it has no known source or no name.
    public static func parse(_ id: String) -> (source: Source, name: String)? {
        guard let colon = id.firstIndex(of: ":"), let source = Source(rawValue: String(id[..<colon])) else { return nil }
        let name = String(id[id.index(after: colon)...])
        return name.isEmpty ? nil : (source, name)
    }
}

// MARK: - What there is

extension AlarmSound {
    /// The 12 macOS sounds the list offers, in the spec's order.
    public static let macOSNames = [
        "Glass", "Hero", "Ping", "Submarine", "Sosumi", "Funk", "Bottle", "Blow", "Morse", "Tink", "Frog", "Pop",
    ]
    /// Where macOS keeps them.
    public static let systemSoundsDirectory = URL(filePath: "/System/Library/Sounds", directoryHint: .isDirectory)
    /// The extensions a macOS sound may have; today they're all `.aiff`.
    private static let macOSExtensions = ["aiff", "aif", "caf", "wav"]

    /// The macOS sounds this Mac has, in the spec's order. One it doesn't have is left out of the list.
    public static func macOSSounds(in directory: URL = systemSoundsDirectory) -> [AlarmSound] {
        macOSNames.compactMap { macOSSound(named: $0, in: directory) }
    }

    /// sTools' own alarms, in their order. They're bundled, so they're always there.
    public static var sToolsSounds: [AlarmSound] {
        STAlarmSound.allCases.compactMap { alarm in
            alarm.resourceURL.map { AlarmSound(source: .sTools, name: alarm.rawValue, title: alarm.title, url: $0) }
        }
    }

    /// The owner's file `name` in `directory` (`Sounds/`), titled by its name without the extension. Whether
    /// it exists isn't checked here.
    public static func ownFile(named name: String, in directory: URL) -> AlarmSound {
        let stem = (name as NSString).deletingPathExtension
        return AlarmSound(source: .file, name: name, title: stem.isEmpty ? name : stem,
                          url: directory.appending(path: name, directoryHint: .notDirectory))
    }

    private static func macOSSound(named name: String, in directory: URL) -> AlarmSound? {
        guard macOSNames.contains(name) else { return nil }
        for pathExtension in macOSExtensions {
            let url = directory.appending(path: "\(name).\(pathExtension)", directoryHint: .notDirectory)
            if isRegularFile(url) { return AlarmSound(source: .macOS, name: name, title: name, url: url) }
        }
        return nil
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}

// MARK: - The saved sound

extension AlarmSound {
    /// The sound a saved ID plays: the one it names, or Ping when that one is gone (decision 12).
    public struct Resolution: Equatable, Sendable {
        /// What plays.
        public let sound: AlarmSound
        /// The ID names a sound that's gone, such as a deleted file, so Ping plays instead. The page says so.
        public let isMissing: Bool

        public init(sound: AlarmSound, isMissing: Bool) {
            self.sound = sound
            self.isMissing = isMissing
        }
    }

    /// Finds the sound `id` names. A `file:` ID only ever names a plain, visible file directly inside
    /// `soundsDirectory`. A missing sound falls back to Ping, and on a Mac without Ping to sTools' first alarm.
    public static func resolve(
        _ id: String, soundsDirectory: URL, macOSDirectory: URL = systemSoundsDirectory
    ) -> Resolution {
        if let sound = find(id, soundsDirectory: soundsDirectory, macOSDirectory: macOSDirectory) {
            return Resolution(sound: sound, isMissing: false)
        }
        return Resolution(sound: fallback(macOSDirectory: macOSDirectory), isMissing: true)
    }

    /// What plays instead of a sound that's gone: Ping, or sTools' first alarm on a Mac without Ping.
    public static func fallback(macOSDirectory: URL = systemSoundsDirectory) -> AlarmSound {
        macOSSound(named: "Ping", in: macOSDirectory)
            ?? sToolsSounds.first
            ?? AlarmSound(source: .macOS, name: "Ping", title: "Ping",
                          url: macOSDirectory.appending(path: "Ping.aiff", directoryHint: .notDirectory))
    }

    private static func find(_ id: String, soundsDirectory: URL, macOSDirectory: URL) -> AlarmSound? {
        guard let (source, name) = parse(id) else { return nil }
        switch source {
        case .macOS:
            return macOSSound(named: name, in: macOSDirectory)
        case .sTools:
            return sToolsSounds.first { $0.name == name }
        case .file:
            guard SettingsLayout.isValidSoundFileName(name) else { return nil }
            let sound = ownFile(named: name, in: soundsDirectory)
            return isRegularFile(sound.url) ? sound : nil
        }
    }
}

// MARK: - Length

extension AlarmSound {
    /// The sound's length in seconds, read from its file's header: what the alarm's rings are spaced by. nil when
    /// the file can't be read as sound.
    public var length: TimeInterval? { Self.length(of: url) }

    public static func length(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
}
