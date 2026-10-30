import AVFoundation
import Foundation
import Testing
@testable import Backdrop

/// The controller driving the real players on real generated files, with only the clock and the notification centers the
/// rig's own. Nothing is ordered onto a screen.
@MainActor
private final class MadePlayers {
    var players: [any BackdropPlayer] = []
}

@MainActor
@Suite("Animated fill with the real players", .serialized)
struct BackdropAnimatedIntegrationTests {
    private func rig(_ made: MadePlayers) -> AnimatedRig {
        AnimatedRig(makePlayer: { url, clock in
            let player = BackdropAnimationFile.makePlayer(for: url, clock: clock)
            made.players.append(player)
            return player
        })
    }

    @Test func aRealVideoPlaysWhileTheBackdropShowsAndStopsWhenMinecraftIsMinimized() async throws {
        let made = MadePlayers()
        let rig = rig(made)
        let movie = try await TestMedia.writeMovie(to: rig.folder.file("clip.mp4"), colors: [.red, .blue])
        await rig.controller.importAnimation(from: movie)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let video = try #require(made.players.first as? BackdropVideoPlayer)
        #expect(await waitUntil { video.seconds > 0.3 }, "the movie plays under the controller")

        rig.minecraft(minimized: true)
        #expect(await waitUntil { video.rate == 0 })
        let stoppedAt = video.seconds
        try? await Task.sleep(for: .milliseconds(300))
        #expect(abs(video.seconds - stoppedAt) < 0.02, "and it doesn't move while the backdrop is hidden")

        rig.minecraft(minimized: false)
        #expect(await waitUntil { video.seconds > stoppedAt + 0.1 || video.seconds < stoppedAt - 0.3 }, "it carries on when Minecraft is back")
        #expect(made.players.count == 1, "with the same player, the file not opened again")
    }

    @Test func switchingTheToolOffReleasesARealVideo() async throws {
        let made = MadePlayers()
        let rig = rig(made)
        await rig.controller.importAnimation(from: try await TestMedia.writeMovie(to: rig.folder.file("clip.mp4"), colors: [.red, .blue]))
        rig.controller.setEnabled(true)
        let video = try #require(made.players.first as? BackdropVideoPlayer)
        #expect(await waitUntil { video.seconds > 0.1 })
        rig.controller.setEnabled(false)
        #expect(!video.isPlaying)
        #expect((video.mediaLayer as? AVPlayerLayer)?.player == nil)
    }

    @Test func aRealGIFFollowsItsFramesAndTheBackdropShowingAndHiding() async throws {
        let made = MadePlayers()
        let rig = rig(made)
        let gif = TestMedia.writeGIF(to: rig.folder.file("loop.gif"), colors: [.red, .green, .blue], delays: [0.25, 0.25, 0.25])
        await rig.controller.importAnimation(from: gif)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let player = try #require(made.players.first as? BackdropGIFPlayer)
        #expect(await waitUntil { player.shownFrameIndex == 0 && player.cachedFrameIndices.count == 3 })
        rig.clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 1)

        rig.minecraft(minimized: true)
        #expect(!player.isPlaying)
        #expect(rig.clock.waiting.isEmpty, "nothing is scheduled while the backdrop is hidden")
        rig.clock.advance(by: 5)
        #expect(player.shownFrameIndex == 1)

        rig.minecraft(minimized: false)
        #expect(player.isPlaying)
        rig.clock.advance(by: 0.25)
        #expect(player.shownFrameIndex == 2, "it goes on from the frame it stopped at")
    }

    @Test func aGIFAndAVideoOnTwoDisplaysEachPlayOnTheirOwn() async throws {
        let made = MadePlayers()
        let rig = AnimatedRig(displays: [displayOne, displayTwo], makePlayer: { url, clock in
            let player = BackdropAnimationFile.makePlayer(for: url, clock: clock)
            made.players.append(player)
            return player
        })
        rig.controller.setCovered(true, displayID: displayTwo.id)
        await rig.controller.importAnimation(from: TestMedia.writeGIF(to: rig.folder.file("loop.gif"), colors: [.red, .green], delays: [0.25, 0.25]))
        await rig.controller.importAnimation(from: try await TestMedia.writeMovie(to: rig.folder.file("clip.mp4"), colors: [.red, .blue]),
                                             forDisplayID: displayTwo.id)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(made.players.count == 2)
        #expect(made.players.contains { $0 is BackdropGIFPlayer } && made.players.contains { $0 is BackdropVideoPlayer })
        #expect(await waitUntil { (made.players.compactMap { $0 as? BackdropVideoPlayer }.first?.seconds ?? 0) > 0.2 })
    }
}
