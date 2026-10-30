import CoreGraphics
import CoreMedia
import Foundation
import os
import STPlatform
import Testing
@testable import ScreenRecording

/// A recording of a layout with a web page: the page's sound arrives as its own track and goes into the mix. The
/// captures are fakes, so no sound is tapped and nothing asks for a permission.
@Suite("A recording with a web page's sound", .serialized)
struct WebPageAudioRecordingTests {
    private let canvas = PixelSize(width: 320, height: 180)

    private func solidFrame(at seconds: Double) -> VideoFrame {
        VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: Int(seconds * 30), size: canvas), hostTime: .seconds(seconds))
    }

    private func record(switchedOn: Bool, in directory: URL) async throws -> (RecordingSession, MovieInfo) {
        var layout = RecordingLayout()
        layout.add(VideoSource(kind: .browser(url: "https://www.twitch.tv/popout/someone/chat"),
                               frame: PixelRect(x: 160, y: 0, width: 160, height: 90), on: canvas))
        layout.includesWebPageAudio = switchedOn
        layout.webPageAudioVolume = 0.75
        let base = FakeVideoCapture(), game = FakeAudioCapture(), page = FakeAudioCapture()
        var sounds: [AudioTrackID: any AudioCapture] = [.minecraft: game]
        if switchedOn { sounds[.webPages] = page }
        let rig = CaptureRig(video: [.base: base], audio: sounds, minimizedShowsNothing: false)
        await rig.start()
        let clock = ManualClock(100)
        let driver = ManualTickDriver()
        var options = RecordingOptions()
        options.frameRate = .fps30
        let session = try RecordingSession(
            configuration: .init(layout: layout, options: options, canvas: canvas, baseName: "page", directory: directory),
            rig: rig, clock: clock, driver: driver)
        base.push(.frame(solidFrame(at: 100)))
        try session.start()
        for i in 0..<30 {
            let now = 100 + Double(i) / 30
            game.push(frames: 1600, at: now, frequency: 440)
            if switchedOn { page.push(frames: 1600, at: now, frequency: 880) }
            if i % 3 == 0 { base.push(.frame(solidFrame(at: now))) }
            clock.set(now + 0.001)
            driver.fire()
            try await Task.sleep(for: .milliseconds(4))
        }
        for i in 30..<40 {
            let now = 100 + Double(i) / 30
            game.push(frames: 1600, at: now, frequency: 440)
            if switchedOn { page.push(frames: 1600, at: now, frequency: 880) }
        }
        let result = await session.stop()
        await rig.stop()
        return (session, try await MovieInfo.load(try #require(result.files.first)))
    }

    @Test func theWebPagesSoundIsATrackOfItsOwnAfterMinecrafts() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, info) = try await record(switchedOn: true, in: directory)
        #expect(session.tracks.map(\.title) == ["Minecraft", "twitch.tv"])
        #expect(session.tracks.last?.id == .webPages)
        #expect(session.tracks.last?.volume == 0.75)
        #expect(info.audioTracks.map(\.title) == ["Mix", "Minecraft", "twitch.tv"])
        #expect(info.audioTracks.allSatisfy { $0.sampleCount > 0 })
        // The tracks run as long as each other: the page's track is as long as Minecraft's.
        let packets = info.audioTracks.map(\.sampleCount)
        #expect(packets.allSatisfy { abs($0 - packets[0]) <= 2 })
    }

    @Test func withTheSwitchOffThereIsNoTrack() async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, info) = try await record(switchedOn: false, in: directory)
        #expect(session.tracks.map(\.title) == ["Minecraft"])
        #expect(info.audioTracks.map(\.title) == ["Mix", "Minecraft"])
    }

    /// The page's sound is in the mix at its volume, and unmixed on its own track.
    @Test func theMixerSumsThePagesSoundAtItsVolumeAndKeepsItUnmixed() {
        let mixer = AudioMixer(gains: [.minecraft: 1, .webPages: 0.5])
        let out = mixer.mix([.minecraft: [0.25, 0.25], .webPages: [0.5, -0.5]])
        #expect(out.mix == [0.5, 0.0])
        #expect(out.tracks[.webPages] == [0.5, -0.5])
    }
}
