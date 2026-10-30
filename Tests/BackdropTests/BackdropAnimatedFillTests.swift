import AppKit
import CoreGraphics
import Foundation
import STDesign
import Testing
@testable import Backdrop
@testable import STPlatform

@MainActor
@Suite("Animated fill in the backdrop", .serialized)
struct BackdropAnimatedFillTests {
    // MARK: - One player per animated fill

    @Test func anAnimatedFillGetsAPlayerForItsFileAndPlaysItWhileTheBackdropShows() {
        let rig = AnimatedRig()
        rig.animate("Images/loop.mp4")
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.count == 1)
        #expect(rig.log.urls == [rig.imagesDirectory.appending(path: "loop.mp4")])
        #expect(rig.player.isPlaying)
        #expect(rig.controller.isPlayingAnimation(on: displayOne.id))
    }

    @Test func anotherKindOfFillMakesNoPlayer() {
        let rig = AnimatedRig()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.controller.settings.fill.color = "#223344"
        #expect(rig.log.players.isEmpty)
        #expect(!rig.controller.isPlayingAnimation(on: displayOne.id))
    }

    @Test func anAnimatedFillWithNoFileChosenMakesNoPlayerAndDrawsItsBackground() {
        let rig = AnimatedRig()
        rig.controller.settings.fill.kind = .animated
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.isEmpty)
        #expect(rig.controller.shownFill(on: displayOne.id)?.kind == .animated)
    }

    @Test func nothingIsMadeOrPlayedForABackdropThatIsNotShown() {
        let rig = AnimatedRig(minecraftOpen: false)
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.isEmpty, "with no Minecraft there's no backdrop to show, so nothing opens the file")
        #expect(rig.controller.panelCount == 0)
    }

    @Test func reorderingTheBackdropOnEveryAppSwitchStartsNothingNew() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rig.controller.reconcile()
        #expect(rig.log.players.count == 1)
        #expect(rig.player.calls == ["play"], "told once to play, and not again however often it's put under Minecraft")
    }

    // MARK: - Paused while hidden, off, covered or asleep

    @Test func itPausesWhileMinecraftIsMinimizedAndPlaysAgainWhenItIsBack() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.minecraft(minimized: true)
        #expect(!rig.player.isPlaying)
        #expect(rig.player.calls == ["play", "pause"])
        rig.minecraft(minimized: false)
        #expect(rig.player.isPlaying)
        #expect(rig.log.players.count == 1, "the same player carries on: nothing is opened again")
    }

    @Test func itPausesWhenMinecraftGoesFullScreenAndWhenItIsGone() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.minecraft(fullScreen: true)
        #expect(!rig.player.isPlaying)
        rig.minecraft(fullScreen: false)
        #expect(rig.player.isPlaying)
        rig.closeMinecraft()
        #expect(!rig.player.isPlaying)
        #expect(rig.log.players.count == 1)
    }

    @Test func itPausesWhileMinecraftIsNotFocusedIfTheBackdropOnlyShowsThen() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.settings.hidesWhenMinecraftNotFocused = true
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.player.isPlaying)
        rig.minecraft(frontmost: false)
        #expect(!rig.player.isPlaying)
        rig.minecraft(frontmost: true)
        #expect(rig.player.isPlaying)
    }

    @Test func switchingTheToolOffStopsTheAnimationAndLetsItGo() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        let first = rig.player
        rig.controller.setEnabled(false)
        #expect(first.isStopped)
        #expect(!first.isPlaying)
        #expect(rig.controller.panelCount == 0)
        #expect(rig.clock.waiting.isEmpty, "and nothing is left waiting on a timer")

        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.count == 2, "switching on again opens the file afresh")
        #expect(rig.player !== first)
        #expect(rig.player.isPlaying)
    }

    @Test func itPausesWhileTheScreensSleepAndPlaysWhenTheyWake() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.screensSleep()
        #expect(!rig.player.isPlaying)
        rig.screensSleep()
        #expect(rig.player.calls == ["play", "pause"], "a second notice changes nothing")
        rig.screensWake()
        #expect(rig.player.isPlaying)
    }

    @Test func aBackdropThatIsHiddenWhileTheScreensWakeStaysPaused() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.screensSleep()
        rig.minecraft(minimized: true)
        rig.screensWake()
        #expect(!rig.player.isPlaying, "waking the screens doesn't show a backdrop that is hidden")
    }

    @Test func screensThatSleepWhileTheToolIsOffDontPlayItOnWhenItComesOn() {
        let rig = AnimatedRig()
        rig.animate()
        rig.screensSleep()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.count == 1)
        #expect(rig.player.isPlaying, "the tool listens for sleep only while it's on, so a stale notice can't hold it back")
    }

    @Test func itPausesWhileTheWindowServerSaysThePanelIsWhollyCoveredAndPlaysWhenItIsNot() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.panelVisibilityChanges(canBeSeen: false)
        #expect(!rig.player.isPlaying)
        rig.panelVisibilityChanges(canBeSeen: true)
        #expect(rig.player.isPlaying)
    }

    @Test func aPanelThatStaysCoveredStaysPausedThroughEveryAppSwitch() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.panelVisibilityChanges(canBeSeen: false)
        rig.workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rig.controller.reconcile()
        #expect(!rig.player.isPlaying)
    }

    /// A missed notice can't leave it paused for good: the next re-order looks again.
    @Test func aPanelTheWindowServerNoLongerCallsCoveredPlaysAgainAtTheNextReorder() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.panelVisibilityChanges(canBeSeen: false)
        #expect(!rig.player.isPlaying)
        rig.log.panelsCanBeSeen = true // the notice that it can be seen again never arrives
        #expect(!rig.player.isPlaying)
        rig.workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(rig.player.isPlaying)
    }

    /// Looking again never covers a panel: that is for the window server's notice, since a panel just ordered in may not
    /// have its visibility yet.
    @Test func reorderingNeverCoversAPanelBySelf() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.log.panelsCanBeSeen = false // no notice has said so
        rig.workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rig.controller.reconcile()
        #expect(rig.player.isPlaying)
    }

    @Test func aPanelOrderedInAgainStartsAsSeenWhateverItWasBefore() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.panelVisibilityChanges(canBeSeen: false)
        rig.minecraft(minimized: true)
        rig.log.panelsCanBeSeen = true
        rig.minecraft(minimized: false)
        #expect(rig.player.isPlaying, "the covered state of a panel that has been out of sight doesn't hold it back")
    }

    @Test func aVisibilityNoticeForAHiddenPanelChangesNothing() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.minecraft(minimized: true)
        rig.panelVisibilityChanges(canBeSeen: true)
        #expect(!rig.player.isPlaying)
    }

    @Test func theToolListensForSleepAndVisibilityOnlyWhileItIsOn() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        let player = rig.player
        rig.controller.setEnabled(false)
        let calls = player.calls
        rig.screensSleep()
        rig.screensWake()
        rig.windows.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        #expect(player.calls == calls)
    }

    // MARK: - The fill changes

    @Test func changingOnlyTheFitOrTheBackgroundKeepsTheSamePlayerGoing() {
        let rig = AnimatedRig()
        rig.animate(mode: .fill)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.controller.settings.fill.imageContentMode = .fit
        rig.controller.settings.fill.imageBackgroundColor = "#112233"
        #expect(rig.log.players.count == 1)
        #expect(rig.player.calls == ["play"])
        #expect(rig.controller.shownFill(on: displayOne.id)?.imageContentMode == .fit)
        #expect(rig.controller.shownFill(on: displayOne.id)?.imageBackgroundColor == "#112233")
        #expect(rig.clock.waiting.isEmpty, "and there is nothing to fade, so nothing waits to clean up")
    }

    @Test func anotherFileGetsANewPlayerAndTheOldOneStopsOnceTheFadeIsOver() {
        let rig = AnimatedRig()
        rig.animate("Images/one.mp4")
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let old = rig.player
        rig.animate("Images/two.mp4")
        #expect(rig.log.players.count == 2)
        let new = rig.player
        #expect(new !== old)
        #expect(new.isPlaying)
        #expect(!old.isPlaying, "the old picture is held while it fades")
        #expect(!old.isStopped)
        #expect(rig.clock.waiting.count == 1)

        rig.clock.advance(by: 0.3)
        #expect(!old.isStopped, "the default fade is 0.3 s, and the old fill is stopped a moment after it")
        rig.clock.advance(by: 0.1)
        #expect(old.isStopped)
        #expect(rig.clock.waiting.isEmpty)
        #expect(new.isPlaying && !new.isStopped)
    }

    @Test func leavingAnAnimatedFillForAColorStopsItAfterTheFade() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let old = rig.player
        rig.controller.settings.fill.kind = .color
        #expect(!old.isPlaying)
        #expect(rig.controller.shownFill(on: displayOne.id)?.kind == .color)
        rig.clock.advance(by: 0.4)
        #expect(old.isStopped)
        #expect(rig.log.players.count == 1)
    }

    @Test func goingBackToAnimatedOpensTheFileAfresh() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.controller.settings.fill.kind = .color
        rig.clock.advance(by: 0.4)
        rig.controller.settings.fill.kind = .animated
        #expect(rig.log.players.count == 2)
        #expect(rig.player.isPlaying)
    }

    @Test func comingFromAColorStartsAPlayerAndTheColorHasNone() {
        let rig = AnimatedRig()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.isEmpty)
        rig.animate()
        #expect(rig.log.players.count == 1)
        #expect(rig.player.isPlaying)
        #expect(rig.clock.waiting.isEmpty, "a color fill has no player to let go of")
    }

    @Test func theFadeLengthIsTheSettingAndTheCleanupWaitsForIt() {
        let rig = AnimatedRig()
        rig.controller.settings.fillTransitionSeconds = 1.0
        rig.animate("Images/one.mp4")
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        let old = rig.player
        rig.animate("Images/two.mp4")
        rig.clock.advance(by: 1.0)
        #expect(!old.isStopped)
        rig.clock.advance(by: 0.15)
        #expect(old.isStopped)
    }

    /// Reduce animations takes away the fade, not the movie (spec 3.4).
    @Test func reduceAnimationsEndsTheFadeButTheAnimationKeepsPlaying() {
        let reduced = STTheme(motionMode: .reduced)
        let rig = AnimatedRig(theme: reduced)
        rig.animate("Images/one.mp4")
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.controller.fillTransitionSeconds == 0)
        #expect(rig.player.isPlaying, "the movie plays")
        let old = rig.player
        rig.animate("Images/two.mp4")
        #expect(rig.player.isPlaying, "and so does the next, with Reduce animations on")
        rig.clock.advance(by: 0.1)
        #expect(old.isStopped, "the old fill goes at once: no fade to wait for")
    }

    @Test func macOSReduceMotionLeavesTheAnimationAloneToo() {
        let theme = STTheme(systemReduceMotion: true)
        let rig = AnimatedRig(theme: theme)
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.controller.fillTransitionSeconds == 0)
        #expect(rig.player.isPlaying)
    }

    @Test func theOpacityChangesAtOnceWithoutTouchingThePlayer() {
        let rig = AnimatedRig()
        rig.animate()
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.controller.settings.opacityPercent = 40
        #expect(rig.player.calls == ["play"])
        #expect(rig.log.players.count == 1)
    }

    // MARK: - Each display has its own

    @Test func eachCoveredDisplayPlaysItsOwnFill() {
        let rig = AnimatedRig(displays: [displayOne, displayTwo])
        rig.animate("Images/main.mp4")
        var other = BackdropSettings.Fill()
        other.kind = .animated
        other.animationName = "Images/other.gif"
        rig.controller.setCovered(true, displayID: displayTwo.id)
        rig.controller.setDisplayFill(other, for: displayTwo.id)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.count == 2)
        #expect(Set(rig.log.urls.map(\.lastPathComponent)) == ["main.mp4", "other.gif"])
        let allPlaying = rig.log.players.allSatisfy { $0.isPlaying }
        #expect(allPlaying)
        #expect(rig.controller.isPlayingAnimation(on: displayOne.id) && rig.controller.isPlayingAnimation(on: displayTwo.id))
    }

    @Test func aDisplayWithAColorPlaysNothingBesideAnotherThatPlaysAnAnimation() {
        let rig = AnimatedRig(displays: [displayOne, displayTwo])
        rig.animate()
        rig.controller.setCovered(true, displayID: displayTwo.id)
        rig.controller.setDisplayFill({ var fill = BackdropSettings.Fill(); fill.color = "#445566"; return fill }(), for: displayTwo.id)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.log.players.count == 1)
        #expect(rig.controller.isPlayingAnimation(on: displayOne.id))
        #expect(!rig.controller.isPlayingAnimation(on: displayTwo.id))
    }

    @Test func eachDisplaysAnimationPausesAndPlaysOnItsOwn() {
        let rig = AnimatedRig(displays: [displayOne, displayTwo])
        rig.animate("Images/main.mp4")
        var other = BackdropSettings.Fill()
        other.kind = .animated
        other.animationName = "Images/other.gif"
        rig.controller.setCovered(true, displayID: displayTwo.id)
        rig.controller.setDisplayFill(other, for: displayTwo.id)
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        rig.panelVisibilityChanges(canBeSeen: false, on: displayTwo.id)
        #expect(rig.controller.isPlayingAnimation(on: displayOne.id))
        #expect(!rig.controller.isPlayingAnimation(on: displayTwo.id), "only the covered display's animation stops")
    }

    // MARK: - Problems with the file

    @Test func aFileThatIsGoneFallsBackToTheBackgroundAndThePageSaysSo() {
        let rig = AnimatedRig(makePlayer: { url, clock in BackdropAnimationFile.makePlayer(for: url, clock: clock) })
        rig.animate("Images/gone.mp4")
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.controller.animationProblem(for: rig.controller.settings.fill) == BackdropPlayerMessages.cantPlay)
        #expect(rig.controller.animationProblem(for: BackdropSettings.Fill()) == nil, "another kind of fill has no such problem")
        #expect(rig.controller.shownFill(on: displayOne.id)?.kind == .animated)
    }

    @Test func aPlayerThatFailsAfterStartingIsReportedAndClearedWhenAnotherFileIsChosen() {
        let rig = AnimatedRig()
        rig.animate("Images/one.mp4")
        rig.controller.setEnabled(true)
        defer { rig.controller.setEnabled(false) }
        #expect(rig.controller.animationProblem(for: rig.controller.settings.fill) == nil)
        rig.player.fail("sTools can\u{2019}t play this file. Choose another one.")
        #expect(rig.controller.animationProblem(for: rig.controller.settings.fill) == "sTools can\u{2019}t play this file. Choose another one.")
        rig.animate("Images/two.mp4")
        #expect(rig.controller.animationProblem(for: rig.controller.settings.fill) == nil, "the new file has no problem")
    }
}
