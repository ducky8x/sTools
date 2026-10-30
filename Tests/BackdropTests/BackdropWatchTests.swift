import STDesign
import Testing
@testable import Backdrop

// While the Window Backdrop is on it watches Minecraft's window and the displays, and the theme's motion setting: an
// observation that re-arms itself after each change. Switching the tool off and on again used to leave the old watch
// running and start another, so after n switch-ons one change of Minecraft ran n rounds of the same work, and an off tool
// kept watching. One watch is armed at a time, as the NBB Overlay's and Crosshair's are.

@MainActor
@Suite("Backdrop watching Minecraft", .serialized)
struct BackdropWatchTests {
    @Test func oneChangeOfMinecraftIsOneRoundHoweverOftenTheToolWasSwitchedOn() async {
        let rig = AnimatedRig()
        for _ in 0..<4 {
            rig.controller.setEnabled(true)
            rig.controller.setEnabled(false)
        }
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let before = rig.controller.watchRounds

        rig.changeMinecraft(minimized: true)
        #expect(await waitUntil { rig.controller.watchRounds > before })
        // Anything else that was going to run has run by now.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 1,
                "one change of Minecraft is one round, not one per switch-on (it ran \(rig.controller.watchRounds - before))")

        rig.changeMinecraft(minimized: false)
        #expect(await waitUntil { rig.controller.watchRounds > before + 1 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 2)
    }

    @Test func aSwitchedOffToolDoesNotWatchAtAll() async {
        let rig = AnimatedRig()
        rig.controller.setEnabled(true)
        rig.controller.setEnabled(false)
        let before = rig.controller.watchRounds

        rig.changeMinecraft(minimized: true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before, "off: nothing is watched, and nothing starts the watch again")
        rig.changeMinecraft(minimized: false)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before)

        // Switched on again, it watches once, from then on.
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.changeMinecraft(minimized: true)
        #expect(await waitUntil { rig.controller.watchRounds > before })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 1)
    }

    /// A tool switched off and on again before the watch has heard anything keeps the one watch it has.
    @Test func switchingOffAndOnAgainBeforeAChangeKeepsTheOneWatch() async {
        let rig = AnimatedRig()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let before = rig.controller.watchRounds
        rig.controller.setEnabled(false)
        rig.controller.setEnabled(true)

        rig.changeMinecraft(minimized: true)
        #expect(await waitUntil { rig.controller.watchRounds > before })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 1)
    }

    /// What the one watch does with a change is the same as before: the backdrop follows Minecraft.
    @Test func theOneWatchStillBringsThePanelInLineWithMinecraft() async {
        let rig = AnimatedRig()
        rig.animate()
        for _ in 0..<3 {
            rig.controller.setEnabled(true)
            rig.controller.setEnabled(false)
        }
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.player.isPlaying)
        rig.changeMinecraft(minimized: true)
        #expect(await waitUntil { !rig.player.isPlaying }, "hidden when Minecraft is minimized, with no one calling reconcile")
        rig.changeMinecraft(minimized: false)
        #expect(await waitUntil { rig.player.isPlaying })
    }

    @Test func oneWatchOnTheMotionSettingIsStartedHoweverOftenTheToolWasSwitchedOn() async {
        let theme = STTheme()
        let rig = AnimatedRig(theme: theme)
        for _ in 0..<4 {
            rig.controller.setEnabled(true)
            rig.controller.setEnabled(false)
        }
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.controller.motionWatchesStarted == 1, "the watch from the first switch-on is still armed, so no other is started")
    }
}
