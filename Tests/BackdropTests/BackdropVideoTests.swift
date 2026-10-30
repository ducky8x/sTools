import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import Backdrop

/// The real video player on short movies the tests generate. Nothing is shown anywhere: the player's layer is never
/// put in a window, and the movies have no sound.
@MainActor
@Suite("Video player", .serialized)
struct BackdropVideoPlayerTests {
    /// A one-second movie, red for the first half and blue for the second.
    private func movie(in folder: TempFolder, name: String = "loop.mp4", fileType: AVFileType = .mp4) async throws -> URL {
        try await TestMedia.writeMovie(to: folder.file(name), colors: [.red, .blue], framesPerColor: 5, framesPerSecond: 10, fileType: fileType)
    }

    @Test func aMovieOpensWithItsPictureSize() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        defer { player.stop() }
        #expect(await waitUntil { player.naturalSize != nil })
        #expect(player.naturalSize == CGSize(width: 128, height: 96))
        #expect(player.failure == nil)
    }

    /// A phone's portrait video is stored sideways with a rotation; the picture is the way up it plays.
    @Test func aRotatedMovieReportsItsPictureTheWayUpItPlays() async throws {
        let folder = TempFolder()
        let url = try await TestMedia.writeMovie(to: folder.file("portrait.mov"), colors: [.green], framesPerColor: 5, width: 128, height: 96,
                                                 fileType: .mov, transform: CGAffineTransform(rotationAngle: .pi / 2))
        let player = BackdropVideoPlayer(url: url)
        defer { player.stop() }
        #expect(await waitUntil { player.naturalSize != nil })
        #expect(player.naturalSize == CGSize(width: 96, height: 128))
    }

    @Test(arguments: [("loop.mov", AVFileType.mov), ("loop.m4v", AVFileType.m4v)])
    func theOtherFormatsAVFoundationPlayOpenToo(name: String, fileType: AVFileType) async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder, name: name, fileType: fileType))
        defer { player.stop() }
        #expect(await waitUntil { player.naturalSize != nil || player.failure != nil })
        #expect(player.naturalSize == CGSize(width: 128, height: 96))
    }

    @Test func itPlaysAndPausesAndPlaysAgain() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        defer { player.stop() }
        #expect(await waitUntil { player.naturalSize != nil })
        #expect(!player.isPlaying, "it starts paused, and nothing plays until it's told to")

        player.play()
        #expect(player.isPlaying)
        #expect(await waitUntil { player.seconds > 0.25 }, "the movie moves on")

        player.pause()
        #expect(!player.isPlaying)
        #expect(await waitUntil { player.rate == 0 })
        let stopped = player.seconds
        try? await Task.sleep(for: .milliseconds(300))
        #expect(abs(player.seconds - stopped) < 0.02, "a paused movie doesn't move (it settles a few thousandths of a second)")

        player.play()
        #expect(await waitUntil { player.seconds > stopped + 0.1 }, "and it carries on")
    }

    @Test func playingBeforeTheMovieIsOpenStartsOnceItIs() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        defer { player.stop() }
        player.play()
        #expect(player.naturalSize == nil)
        #expect(await waitUntil { player.seconds > 0.2 })
    }

    @Test func aMovieThatIsPausedWhileOpeningStaysPaused() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        defer { player.stop() }
        player.play()
        player.pause()
        #expect(await waitUntil { player.naturalSize != nil })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(player.rate == 0)
        #expect(player.seconds < 0.02)
    }

    /// The movie is one second long; time running on past that, and back around, is the loop.
    @Test func itLoopsForever() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        defer { player.stop() }
        player.play()
        var highest = 0.0
        var wraps = 0
        let looped = await waitUntil(seconds: 15) {
            let now = player.seconds
            if now < highest - 0.3 { wraps += 1; highest = now } else { highest = max(highest, now) }
            return wraps >= 2
        }
        #expect(looped, "the movie came back to its start twice")
        #expect(player.failure == nil)
    }

    @Test func itPlaysWithNoSoundAndNoClaimOnTheDisplay() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        defer { player.stop() }
        #expect(player.isMuted)
        #expect(player.volume == 0)
        #expect(!player.preventsDisplaySleep, "a backdrop must never keep the display awake")
        #expect(await waitUntil { player.naturalSize != nil })
        #expect(await player.audioTrackCount() == 0, "no audio track is ever opened")
    }

    @Test func theLayerStretchesTheMovieToItsFrame() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        defer { player.stop() }
        // The host gives the layer the fitted rect; the movie fills exactly that.
        #expect((player.mediaLayer as? AVPlayerLayer)?.videoGravity == .resize)
    }

    @Test func aFileThatIsNotAMovieFails() async throws {
        let folder = TempFolder()
        let text = folder.file("hello.mp4")
        try "not a movie".write(to: text, atomically: true, encoding: .utf8)
        let player = BackdropVideoPlayer(url: text)
        defer { player.stop() }
        var updates = 0
        player.observe { updates += 1 }
        player.play()
        #expect(await waitUntil { player.failure != nil })
        #expect(player.naturalSize == nil)
        #expect(updates == 1)
    }

    @Test func aMissingFileFails() async {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: folder.file("gone.mov"))
        defer { player.stop() }
        #expect(await waitUntil { player.failure != nil })
    }

    @Test func stoppingLetsEverythingGo() async throws {
        let folder = TempFolder()
        let player = BackdropVideoPlayer(url: try await movie(in: folder))
        #expect(await waitUntil { player.naturalSize != nil })
        player.play()
        #expect(await waitUntil { player.seconds > 0.1 })
        player.stop()
        #expect(!player.isPlaying)
        #expect((player.mediaLayer as? AVPlayerLayer)?.player == nil)
        player.play()
        #expect(!player.isPlaying, "a stopped player stays stopped")
    }
}
