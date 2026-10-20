import Foundation
import Testing
@testable import ScreenRecording

@Suite struct AudioSourceTrackTests {
    private func source(_ name: String, volume: Double = 1, kind: AudioSourceKind = .app(bundleID: "x.y")) -> AudioSource {
        AudioSource(kind: kind, name: name, volume: volume)
    }

    @Test func minecraftComesFirstThenSourcesInOrder() {
        let mic = source("Microphone", volume: 0.5, kind: .microphone(uniqueID: "m"))
        let music = source("Music", volume: 1.5)
        let layout = RecordingLayout(audioSources: [mic, music], minecraftAudioVolume: 0.8)
        let tracks = AudioSourceTrack.tracks(for: layout)
        #expect(tracks.map(\.title) == ["Minecraft", "Microphone", "Music"])
        #expect(tracks.map(\.id) == [.minecraft, .source(mic.id), .source(music.id)])
        #expect(tracks.map(\.volume) == [0.8, 0.5, 1.5])
    }

    @Test func minecraftCanBeLeftOut() {
        let layout = RecordingLayout(audioSources: [source("Music")], includesMinecraftAudio: false)
        #expect(AudioSourceTrack.tracks(for: layout).map(\.title) == ["Music"])
    }

    @Test func emptyNamesAndTheMixTitleAreMadeDistinct() {
        let layout = RecordingLayout(audioSources: [source("  "), source("Mix"), source("minecraft"), source("Music"), source("Music")])
        #expect(AudioSourceTrack.tracks(for: layout).map(\.title) == ["Minecraft", "Audio", "Mix 2", "minecraft 2", "Music", "Music 2"])
    }

    @Test func namesAreTrimmed() {
        let layout = RecordingLayout(audioSources: [source("  Discord \n")], includesMinecraftAudio: false)
        #expect(AudioSourceTrack.tracks(for: layout).first?.title == "Discord")
    }

    @Test func theMixerUsesEachTracksVolumeAsItsGain() {
        let layout = RecordingLayout(audioSources: [source("Music", volume: 0.25)], minecraftAudioVolume: 1.5)
        let tracks = AudioSourceTrack.tracks(for: layout)
        let mixer = AudioSourceTrack.mixer(for: tracks)
        #expect(mixer.gain(for: .minecraft) == 1.5)
        #expect(mixer.gain(for: tracks[1].id) == 0.25)
    }

    @Test func noTracksWhenNothingIsRecorded() {
        #expect(AudioSourceTrack.tracks(for: RecordingLayout(includesMinecraftAudio: false)).isEmpty)
    }
}
