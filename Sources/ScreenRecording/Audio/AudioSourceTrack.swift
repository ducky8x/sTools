import Foundation

/// One audio track of the recording file: its source, the name players show, and the volume it has in the mix.
public struct AudioSourceTrack: Equatable, Sendable {
    public static let mixTitle = "Mix"
    public static let minecraftTitle = "Minecraft"

    public var id: AudioTrackID
    public var title: String
    public var volume: Double

    public init(id: AudioTrackID, title: String, volume: Double) {
        self.id = id
        self.title = title
        self.volume = volume
    }

    /// The tracks after the mix, in file order: Minecraft (when included), the web pages' sound (when a web page is on
    /// the canvas and its sound is on), then the layout's audio sources, then sTools' own in-process feeds named in
    /// `feeds` (the ones that want recording, such as *Timer alarm*), each mixed at volume 1. Titles are the source and
    /// feed names, trimmed; an empty name becomes "Audio" and a repeated title gets " 2", " 3", ... so every track is
    /// distinguishable in a player's track menu.
    public static func tracks(for layout: RecordingLayout, feeds: [String] = []) -> [AudioSourceTrack] {
        var tracks: [AudioSourceTrack] = []
        if layout.includesMinecraftAudio {
            tracks.append(AudioSourceTrack(id: .minecraft, title: minecraftTitle, volume: layout.minecraftAudioVolume))
        }
        if layout.recordsWebPageAudio {
            tracks.append(AudioSourceTrack(id: .webPages, title: layout.webPageAudioTitle, volume: layout.webPageAudioVolume))
        }
        for source in layout.audioSources {
            let trimmed = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            tracks.append(AudioSourceTrack(id: .source(source.id), title: trimmed.isEmpty ? "Audio" : trimmed, volume: source.volume))
        }
        var seenFeeds: Set<String> = []
        for name in feeds where seenFeeds.insert(name).inserted {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            tracks.append(AudioSourceTrack(id: .feed(name), title: trimmed.isEmpty ? "Audio" : trimmed, volume: 1))
        }
        var used: Set<String> = [mixTitle.lowercased()]
        for i in tracks.indices {
            let base = tracks[i].title
            var candidate = base
            var n = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base) \(n)"
                n += 1
            }
            used.insert(candidate.lowercased())
            tracks[i].title = candidate
        }
        return tracks
    }

    /// A mixer with each track's volume as its gain.
    public static func mixer(for tracks: [AudioSourceTrack]) -> AudioMixer {
        AudioMixer(gains: Dictionary(tracks.map { ($0.id, Float($0.volume)) }, uniquingKeysWith: { first, _ in first }))
    }
}
