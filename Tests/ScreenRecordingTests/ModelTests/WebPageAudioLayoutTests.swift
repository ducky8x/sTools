import Foundation
import Testing
@testable import ScreenRecording

/// The web pages' sound in the saved layout and in the file's track list (spec 5.4.1).
@Suite("The web pages' sound in the layout")
struct WebPageAudioLayoutTests {
    private let canvas = PixelSize(width: 1920, height: 1080)

    private func page(_ address: String) -> VideoSource {
        VideoSource(kind: .browser(url: address), frame: PixelRect(x: 0, y: 0, width: 640, height: 360), on: canvas)
    }

    private func camera() -> VideoSource {
        VideoSource(kind: .camera(CameraReference(uniqueID: "cam", name: "Cam")), frame: PixelRect(x: 0, y: 0, width: 64, height: 36), on: canvas)
    }

    @Test func aLayoutWithoutAWebPageRecordsNone() {
        var layout = RecordingLayout()
        #expect(layout.includesWebPageAudio, "on by default")
        #expect(!layout.hasWebPages)
        #expect(!layout.recordsWebPageAudio)
        layout.add(camera())
        #expect(!layout.recordsWebPageAudio)
    }

    @Test func aWebPageBringsItsSoundAndTheSwitchTakesItAway() {
        var layout = RecordingLayout()
        layout.add(page("https://example.com"))
        #expect(layout.hasWebPages && layout.recordsWebPageAudio)
        layout.includesWebPageAudio = false
        #expect(layout.hasWebPages && !layout.recordsWebPageAudio)
    }

    @Test func removingTheLastWebPageTakesTheSoundAway() {
        var layout = RecordingLayout()
        let first = page("https://example.com"), second = page("https://example.org")
        layout.add(first)
        layout.add(second)
        layout.removeVideoSource(first.id)
        #expect(layout.recordsWebPageAudio, "one web page is left")
        layout.removeVideoSource(second.id)
        #expect(!layout.recordsWebPageAudio)
    }

    /// One web page is the track's name; with several, the sound is theirs together.
    @Test func theTrackIsNamedForTheOnePageOrForThePagesTogether() {
        var layout = RecordingLayout()
        layout.add(page("https://www.twitch.tv/popout/someone/chat"))
        #expect(layout.webPageAudioTitle == "twitch.tv")
        layout.add(page("https://example.org"))
        #expect(layout.webPageAudioTitle == "Web pages")
    }

    @Test func aPageWithNoHostIsJustAWebPage() {
        var layout = RecordingLayout()
        layout.add(page("not a web address"))
        #expect(layout.webPageAudioTitle == "Web page")
        #expect(RecordingLayout.pageTitle(forAddress: "https://Example.COM:8080/a?b=c") == "example.com")
        #expect(RecordingLayout.pageTitle(forAddress: "https://www.example.com") == "example.com")
        #expect(RecordingLayout.pageTitle(forAddress: "https://wwwx.example.com") == "wwwx.example.com")
    }

    @Test func theWebPagesTrackFollowsMinecraftsAndComesBeforeTheAddedSources() {
        var layout = RecordingLayout(minecraftAudioVolume: 0.8)
        layout.add(page("https://example.com"))
        layout.add(AudioSource(kind: .microphone(uniqueID: "mic"), name: "Mic", volume: 0.5))
        layout.webPageAudioVolume = 1.25
        let tracks = AudioSourceTrack.tracks(for: layout)
        #expect(tracks.map(\.title) == ["Minecraft", "example.com", "Mic"])
        #expect(tracks[1].id == .webPages)
        #expect(tracks.map(\.volume) == [0.8, 1.25, 0.5])
    }

    @Test func noTrackWithoutAPageOrWithTheSwitchOff() {
        var layout = RecordingLayout()
        #expect(!AudioSourceTrack.tracks(for: layout).contains { $0.id == .webPages })
        layout.add(page("https://example.com"))
        #expect(AudioSourceTrack.tracks(for: layout).contains { $0.id == .webPages })
        layout.includesWebPageAudio = false
        #expect(!AudioSourceTrack.tracks(for: layout).contains { $0.id == .webPages })
    }

    /// A player's track menu needs the names apart: a microphone named like the page gets " 2".
    @Test func aNameTheSameAsAnotherTrackGetsANumber() {
        var layout = RecordingLayout()
        layout.add(page("https://example.com"))
        layout.add(AudioSource(kind: .microphone(uniqueID: "mic"), name: "example.com"))
        #expect(AudioSourceTrack.tracks(for: layout).map(\.title) == ["Minecraft", "example.com", "example.com 2"])
    }

    /// A layout saved before the web pages' sound existed has neither key: the sound is on, at full volume.
    @Test func anOlderLayoutFileHasTheSoundOnAtFullVolume() throws {
        let old = #"{"videoSources":[],"audioSources":[],"includesMinecraftAudio":true,"minecraftAudioVolume":1}"#
        let layout = try JSONDecoder().decode(RecordingLayout.self, from: Data(old.utf8))
        #expect(layout.includesWebPageAudio)
        #expect(layout.webPageAudioVolume == 1)
    }

    @Test func theSwitchAndTheVolumeAreSavedAndKept() throws {
        var layout = RecordingLayout()
        layout.add(page("https://example.com"))
        layout.includesWebPageAudio = false
        layout.webPageAudioVolume = 0.4
        let again = try JSONDecoder().decode(RecordingLayout.self, from: JSONEncoder().encode(layout))
        #expect(again == layout)
        #expect(!again.includesWebPageAudio && again.webPageAudioVolume == 0.4)
    }

    @Test func theVolumeStaysInRange() {
        var layout = RecordingLayout()
        layout.webPageAudioVolume = 9
        layout.sanitize()
        #expect(layout.webPageAudioVolume == AudioSource.volumeRange.upperBound)
        layout.webPageAudioVolume = .nan
        layout.sanitize()
        #expect(layout.webPageAudioVolume == 1)
    }

    /// A saved audio source of the kind the first build left out (nothing makes one) loads and is left alone.
    @Test func aSavedBrowserAudioSourceStillLoads() throws {
        let id = UUID()
        let json = """
        {"videoSources":[],"audioSources":[{"id":"\(id.uuidString)","kind":{"type":"browser","videoSourceID":"\(UUID().uuidString)"},"name":"Page","volume":1}],\
        "includesMinecraftAudio":true,"minecraftAudioVolume":1}
        """
        let layout = try JSONDecoder().decode(RecordingLayout.self, from: Data(json.utf8))
        #expect(layout.audioSources.map(\.id) == [id])
    }
}
