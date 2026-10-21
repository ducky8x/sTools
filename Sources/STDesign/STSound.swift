import AVFoundation
import OSLog
import SwiftUI

/// The UI sound set. Each case maps to a bundled `<rawValue>.wav` in `Resources/Sounds`.
public enum STSound: String, CaseIterable, Sendable {
    case click, tick, stamp, page, chime, recordStart, recordStop
}

/// Plays the bundled UI sounds, honoring the in-app sound settings and macOS's
/// "Play user interface sound effects" preference.
@MainActor
public final class STSoundPlayer {
    private let theme: STTheme
    private let systemSoundsEnabled: @MainActor () -> Bool
    private var players: [STSound: AVAudioPlayer] = [:]
    private let logger = Logger(subsystem: "com.ducky8x.sTools", category: "sound")

    /// - Parameter systemSoundsEnabled: Reports whether macOS allows UI sound effects. The default reads
    ///   the system preference and treats an absent value as enabled.
    public init(theme: STTheme,
                systemSoundsEnabled: @escaping @MainActor () -> Bool = STSoundPlayer.systemUISoundsEnabled) {
        self.theme = theme
        self.systemSoundsEnabled = systemSoundsEnabled
    }

    private init(silentTheme: STTheme) {
        theme = silentTheme
        systemSoundsEnabled = { false }
    }

    /// Plays `sound` from the start at the theme's volume, unless sounds are off, the volume is zero or
    /// macOS has UI sound effects turned off. A missing or unreadable resource stays silent.
    public func play(_ sound: STSound) {
        guard Self.shouldPlay(soundsEnabled: theme.soundsEnabled,
                              volume: theme.soundVolume,
                              systemEnabled: systemSoundsEnabled()) else { return }
        guard let player = player(for: sound) else { return }
        player.volume = Float(min(theme.soundVolume, 1))
        player.currentTime = 0
        player.play()
    }

    /// The pure decision behind `play(_:)`.
    public nonisolated static func shouldPlay(soundsEnabled: Bool, volume: Double, systemEnabled: Bool) -> Bool {
        soundsEnabled && volume > 0 && systemEnabled
    }

    /// Reads macOS's "Play user interface sound effects" setting; `true` when it was never set.
    public nonisolated static func systemUISoundsEnabled() -> Bool {
        let value = CFPreferencesCopyAppValue("com.apple.sound.uiaudio.enabled" as CFString,
                                              "com.apple.systemsound" as CFString)
        return (value as? NSNumber)?.boolValue ?? true
    }

    /// Default for views outside an app that injects a real player: never makes a sound.
    public nonisolated static let silent: STSoundPlayer = MainActor.assumeIsolated {
        STSoundPlayer(silentTheme: STTheme(soundsEnabled: false))
    }

    nonisolated static func resourceURL(for sound: STSound) -> URL? {
        STResources.bundle.url(forResource: sound.rawValue, withExtension: "wav", subdirectory: "Resources/Sounds")
    }

    func isPlaying(_ sound: STSound) -> Bool { players[sound]?.isPlaying ?? false }

    /// How many sounds have been loaded. For tests.
    var loadedCount: Int { players.count }

    /// Loads a sound the first time it plays. Loading all of them up front kept an audio queue open for each
    /// for the whole session, sounds that might never play; a sound loads in well under a frame.
    private func player(for sound: STSound) -> AVAudioPlayer? {
        if let player = players[sound] { return player }
        guard let url = Self.resourceURL(for: sound) else {
            logger.error("Missing sound resource \(sound.rawValue, privacy: .public).wav")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            players[sound] = player
            return player
        } catch {
            logger.error("Could not load \(sound.rawValue, privacy: .public).wav: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

public extension EnvironmentValues {
    @Entry var stSoundPlayer: STSoundPlayer = STSoundPlayer.silent
}
