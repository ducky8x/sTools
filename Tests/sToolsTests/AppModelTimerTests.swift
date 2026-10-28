import Foundation
import STDesign
import STPlatform
import Testing
import TimerOverlay
@testable import sTools

/// Timer Overlay in the app (plan T8): its place among the tools, its live status, its key, Set in Hotkeys…, its
/// settings and the Dock. Every harness builds the timer on fakes, so nothing here shows the overlay or rings.
@MainActor
@Suite("AppModel Timer Overlay")
struct AppModelTimerTests {
    // MARK: - The tool

    @Test func theAppOwnsTheTimerControllerInBothHarnessModes() {
        #expect(Harness().model.timerOverlay != nil)
        #expect(Harness(usesRealControllers: true).model.timerOverlay != nil)
    }

    @Test func itNeedsAccessibilityAndHasASwitch() {
        #expect(ToolID.timerOverlay.requiresAccessibility)
        #expect(ToolID.timerOverlay.hasSwitch)
        #expect(ToolID.timerOverlay.trial == .timerOverlay)
        #expect(ToolID.timerOverlay.hotkeyTool == nil)
        let denied = Harness(accessibility: .denied)
        #expect(denied.model.status(of: .timerOverlay) == .needsAccessibility)
        denied.model.setTool(.timerOverlay, on: true)
        #expect(!denied.model.isOn(.timerOverlay))
        #expect(!denied.timer.isEnabled)
    }

    @Test func theSwitchDrivesTheController() {
        let harness = Harness()
        harness.model.setTool(.timerOverlay, on: true)
        #expect(harness.timer.isEnabled)
        harness.model.setTool(.timerOverlay, on: false)
        #expect(!harness.timer.isEnabled)
    }

    // MARK: - The switch starts the countdown (spec 5.6.1, revision 36)

    /// What the app and the overlay show once a start has happened, for comparing two ways of starting.
    private struct Started: Equatable {
        var isOn: Bool
        var isEnabled: Bool
        var phase: TimerPhase
        var isTestRun: Bool
        var text: String
        var status: ToolStatus
        var popIns: [Bool]
        var shown: [TimerOverlayContent]
        var announcements: [TimerAnnouncement]
        var wakeDelays: [TimeInterval]
        var hudLines: [String]
        var isPolling: Bool

        @MainActor
        init(_ harness: Harness) {
            isOn = harness.model.isOn(.timerOverlay)
            isEnabled = harness.timer.isEnabled
            phase = harness.timer.phase
            isTestRun = harness.timer.isTestRun
            text = harness.timer.content.text
            status = harness.model.status(of: .timerOverlay)
            popIns = harness.timerFakes.presenter.popIns
            shown = harness.timerFakes.presenter.contents
            announcements = harness.timerFakes.announcer.announcements
            let now = harness.timerFakes.clock.time
            wakeDelays = harness.timerFakes.scheduler.pending.map { ($0.due - now).rounded() }.sorted()
            hudLines = harness.hotkeyHUD.lines
            isPolling = harness.model.isPollingForTools
        }
    }

    /// ducky, 2026-10-27: switching Timer Overlay on from its switch must start the timer. Before, it only armed the
    /// tool: status Ready, nothing on screen (an idle timer shows nothing) and no countdown until a key or Start.
    @Test func switchingOnFromItsSwitchStartsTheCountdown() {
        let harness = Harness()
        let binding = harness.model.switchBinding(.timerOverlay)
        binding.wrappedValue = true
        #expect(binding.wrappedValue && harness.model.isOn(.timerOverlay) && harness.timer.isEnabled)
        #expect(harness.timer.phase == .counting && !harness.timer.isTestRun && harness.timer.content.text == "02:30")
        #expect(harness.model.status(of: .timerOverlay) == .timer("2:30 left"))
        #expect(harness.timerFakes.presenter.isShowing && harness.timerFakes.presenter.popIns.count == 1)
        #expect(!harness.timerFakes.scheduler.pending.isEmpty, "the countdown ticks")
        #expect(harness.model.isPollingForTools, "Accessibility is watched while the tool is on")
        #expect(harness.hotkeyHUD.presented.isEmpty, "the overlay popping up is the confirmation, as for the key")
    }

    /// The switch and the Start-timer key, while the tool is off, leave the app and the overlay in the same state.
    @Test func theSwitchDoesExactlyWhatTheKeyDoesWhileTheToolIsOff() {
        let key = Harness()
        key.model.hotkeys.showsConfirmation = true
        key.model.handleHotkeyPress([.startTimer])
        let switched = Harness()
        switched.model.hotkeys.showsConfirmation = true
        switched.model.switchBinding(.timerOverlay).wrappedValue = true
        #expect(Started(switched) == Started(key))
        #expect(Started(switched).phase == .counting)
    }

    @Test func theSwitchStartsTheSavedDurationAndKeepsItWhateverItIs() {
        let harness = Harness()
        harness.timer.settings.durationSeconds = 10
        harness.model.switchBinding(.timerOverlay).wrappedValue = true
        #expect(harness.timer.content.text == "00:10" && harness.timer.settings.durationSeconds == 10)
        #expect(harness.model.status(of: .timerOverlay) == .timer("0:10 left"))
    }

    @Test func theSwitchRunsTheCountdownToZeroAndTheOverlayLeaves() {
        let harness = Harness()
        harness.timer.settings.durationSeconds = 5
        harness.model.switchBinding(.timerOverlay).wrappedValue = true
        harness.timerFakes.scheduler.fire(until: { harness.timer.phase == .idle })
        #expect(harness.timerFakes.alarm.rings == 1 && !harness.timerFakes.presenter.isShowing)
        #expect(harness.model.isOn(.timerOverlay), "a finished run leaves the tool on and ready")
        #expect(harness.model.status(of: .timerOverlay) == .timer("Ready"))
    }

    @Test func switchingOffCancelsTheCountdownAsBefore() {
        let harness = Harness()
        let binding = harness.model.switchBinding(.timerOverlay)
        binding.wrappedValue = true
        harness.timerFakes.clock.time += 3
        binding.wrappedValue = false
        #expect(!harness.model.isOn(.timerOverlay) && !harness.timer.isEnabled && harness.timer.phase == .idle)
        #expect(harness.model.status(of: .timerOverlay) == .off)
        #expect(!harness.timerFakes.presenter.isShowing && harness.timerFakes.presenter.popOuts.count == 1)
        #expect(harness.timerFakes.scheduler.pending.isEmpty && !harness.timerFakes.alarm.isPlaying)
        #expect(!harness.model.isPollingForTools)
        #expect(harness.hotkeyHUD.presented.isEmpty, "the switch says nothing over the game, as before")
    }

    @Test func switchingOffMidAlarmStopsItAndOnAgainStartsFresh() {
        let harness = Harness()
        harness.timer.settings.durationSeconds = 3
        let binding = harness.model.switchBinding(.timerOverlay)
        binding.wrappedValue = true
        harness.timerFakes.scheduler.fire(until: { harness.timer.phase == .ringing })
        #expect(harness.timerFakes.alarm.isPlaying)
        binding.wrappedValue = false
        #expect(!harness.timerFakes.alarm.isPlaying && harness.timer.phase == .idle)
        harness.timerFakes.clock.time += 5
        binding.wrappedValue = true
        #expect(harness.timer.phase == .counting && harness.timer.content.text == "00:03")
        #expect(harness.timerFakes.presenter.popIns.count == 2)
    }

    @Test func withoutAccessibilityTheSwitchStartsNothing() {
        let harness = Harness(accessibility: .denied)
        harness.model.switchBinding(.timerOverlay).wrappedValue = true
        #expect(!harness.model.isOn(.timerOverlay) && !harness.timer.isEnabled && harness.timer.phase == .idle)
        #expect(harness.model.status(of: .timerOverlay) == .needsAccessibility)
        #expect(harness.timerFakes.presenter.popIns.isEmpty && harness.timerFakes.scheduler.pending.isEmpty)
        #expect(harness.timerFakes.announcer.announcements.isEmpty)
    }

    /// Only the key's presses make a double press: a key tapped right after the switch restarts the countdown (the
    /// press table's counting row) instead of cancelling it and switching the tool off.
    @Test func theSwitchIsNotAKeyPress() {
        let harness = Harness()
        harness.model.switchBinding(.timerOverlay).wrappedValue = true
        harness.timerFakes.clock.time += 0.2
        harness.model.handleHotkeyPress([.startTimer])
        #expect(harness.model.isOn(.timerOverlay) && harness.timer.phase == .counting)
        #expect(harness.timerFakes.presenter.popIns.count == 1, "restarted in place, not popped in again")
        harness.timerFakes.clock.time += 0.2
        harness.model.handleHotkeyPress([.startTimer])
        #expect(!harness.model.isOn(.timerOverlay), "two presses are still a double press")
    }

    /// The other tools' switches only switch the tool, as before.
    @Test func theOtherToolsSwitchesJustSwitchTheTool() throws {
        let harness = Harness()
        harness.model.switchBinding(.crosshair).wrappedValue = true
        #expect(harness.model.isOn(.crosshair))
        #expect(try #require(harness.controllers[.crosshair]).calls == [true])
        #expect(!harness.model.isOn(.timerOverlay) && harness.timer.phase == .idle)
    }

    // MARK: - Where the switch does not start the countdown

    /// "Restore tools that were on at quit" switches a tool back on at launch, but only a person's switch-on starts
    /// the countdown: a launch never rings or pops up a timer by itself.
    @Test func restoringTheToolAtLaunchSwitchesItOnWithoutStartingACountdown() {
        let harness = Harness()
        harness.model.generalBinding(\.restoreToolsAtQuit).wrappedValue = true
        harness.model.general.toolsOnAtQuit = [ToolID.timerOverlay.rawValue]
        harness.model.restoreToolsIfNeeded()
        #expect(harness.model.isOn(.timerOverlay) && harness.timer.isEnabled)
        #expect(harness.timer.phase == .idle && harness.model.status(of: .timerOverlay) == .timer("Ready"))
        #expect(harness.timerFakes.presenter.popIns.isEmpty && !harness.timerFakes.presenter.isShowing)
        #expect(harness.timerFakes.scheduler.pending.isEmpty && harness.timerFakes.announcer.announcements.isEmpty)
    }

    /// A whole quit and launch: a countdown the switch started is cancelled at quit, the tool is recorded as on, and
    /// the next launch restores the tool alone.
    @Test func aQuitDuringACountdownRestoresTheToolReadyNotCounting() async {
        let harness = Harness()
        harness.model.generalBinding(\.restoreToolsAtQuit).wrappedValue = true
        harness.model.switchBinding(.timerOverlay).wrappedValue = true
        #expect(harness.timer.phase == .counting)
        await harness.model.shutDown()
        #expect(harness.model.general.toolsOnAtQuit == [ToolID.timerOverlay.rawValue])
        #expect(!harness.model.isOn(.timerOverlay) && harness.timer.phase == .idle)
        let startsBeforeLaunch = harness.timerFakes.announcer.announcements.count
        harness.model.restoreToolsIfNeeded()
        #expect(harness.model.isOn(.timerOverlay) && harness.timer.phase == .idle)
        #expect(harness.timerFakes.announcer.announcements.count == startsBeforeLaunch, "nothing started")
        #expect(!harness.timerFakes.presenter.isShowing && harness.timerFakes.scheduler.pending.isEmpty)
    }

    @Test func aToolThatCannotSwitchOnAtLaunchStaysOffAndStartsNothing() {
        let harness = Harness(accessibility: .denied)
        harness.model.generalBinding(\.restoreToolsAtQuit).wrappedValue = true
        harness.model.general.toolsOnAtQuit = [ToolID.timerOverlay.rawValue]
        harness.model.restoreToolsIfNeeded()
        #expect(!harness.model.isOn(.timerOverlay) && harness.timer.phase == .idle)
        #expect(harness.timerFakes.announcer.announcements.isEmpty)
    }

    /// Reset All Tools puts the settings back and leaves the switch where it was: off stays off and starts nothing,
    /// and a countdown under way is neither restarted nor cancelled (the next run uses the default length).
    @Test func resettingTheToolsNeverStartsOrSwitchesAnything() {
        let off = Harness()
        off.timer.settings.durationSeconds = 60
        off.model.resetAllToolsToDefault()
        #expect(!off.model.isOn(.timerOverlay) && off.timer.phase == .idle && off.timer.settings.durationSeconds == 150)
        #expect(off.timerFakes.presenter.popIns.isEmpty && off.timerFakes.announcer.announcements.isEmpty)

        let ready = Harness()
        ready.model.setTool(.timerOverlay, on: true)
        ready.model.resetAllToolsToDefault()
        #expect(ready.model.isOn(.timerOverlay) && ready.timer.phase == .idle)
        #expect(ready.timerFakes.announcer.announcements.isEmpty)

        let counting = Harness()
        counting.timer.settings.durationSeconds = 60
        counting.model.switchBinding(.timerOverlay).wrappedValue = true
        counting.timerFakes.clock.time += 5
        counting.model.resetAllToolsToDefault()
        #expect(counting.model.isOn(.timerOverlay) && counting.timer.phase == .counting)
        #expect(counting.timerFakes.announcer.announcements.count == 1, "no second start")
        #expect(counting.timer.content.text == "00:55", "the run in progress keeps its length")
    }

    // MARK: - Status

    @Test func theStatusIsTheTimersOwnWordsInGoldWhileOn() {
        let harness = Harness()
        #expect(harness.model.status(of: .timerOverlay) == .off)
        harness.model.setTool(.timerOverlay, on: true)
        #expect(harness.model.status(of: .timerOverlay) == .timer("Ready"))
        #expect(harness.model.status(of: .timerOverlay).label == "READY")
        #expect(harness.model.status(of: .timerOverlay).isLit)
        harness.timer.start()
        #expect(harness.model.status(of: .timerOverlay) == .timer("2:30 left"))
        harness.timer.pause()
        #expect(harness.model.status(of: .timerOverlay) == .timer("Paused, 2:30"))
    }

    @Test func onlyOnAndTheTimerReadInGold() {
        #expect(ToolStatus.on.isLit)
        #expect(ToolStatus.timer("Ready").isLit)
        #expect(!ToolStatus.off.isLit)
        #expect(!ToolStatus.needsAccessibility.isLit)
        #expect(!ToolStatus.alwaysAvailable.isLit)
        #expect(ToolStatus.timer("Paused, 99:59:59").label == "PAUSED, 99:59:59")
    }

    // MARK: - The key

    @Test func aStartTimerPressSwitchesTheToolOnAndStartsWithNoConfirmation() {
        let harness = Harness()
        let effect = harness.model.handleHotkeyEvent(.startTimer)
        #expect(effect == nil)
        #expect(harness.model.isOn(.timerOverlay))
        #expect(harness.timer.phase == .counting)
        #expect(harness.timerFakes.presenter.isShowing)
    }

    @Test func aPressThatCannotStartSaysTimerOverlayNeedsAccessibilityWithoutTheSeal() {
        let harness = Harness(accessibility: .denied)
        harness.model.hotkeys.showsConfirmation = true
        harness.model.handleHotkeyPress([.startTimer])
        #expect(harness.hotkeyHUD.lines == ["Timer Overlay needs Accessibility"])
        #expect(harness.hotkeyHUD.presented.first?.sealed == false)
        #expect(!harness.model.isOn(.timerOverlay))
        #expect(harness.timer.phase == .idle)
    }

    @Test func aPressThatActsShowsNoLine() {
        let harness = Harness()
        harness.model.hotkeys.showsConfirmation = true
        harness.model.handleHotkeyPress([.startTimer])
        #expect(harness.hotkeyHUD.presented.isEmpty)
    }

    @Test func aReleaseGoesToTheTimerWithNoConfirmation() {
        let harness = Harness()
        harness.model.handleHotkeyEvent(.startTimer)
        #expect(harness.model.handleHotkeyEvent(.startTimerReleased) == nil)
        harness.model.handleHotkeyPress([.startTimerReleased])
        #expect(harness.hotkeyHUD.presented.isEmpty)
        // A release while the tool is off does nothing at all.
        let off = Harness()
        #expect(off.model.handleHotkeyEvent(.startTimerReleased) == nil)
        #expect(!off.model.isOn(.timerOverlay))
    }

    /// Spec 5.6.2: a double tap of the key cancels the run and switches Timer Overlay off, its switch with it, from
    /// any phase, and says so over the game as every hotkey switch does: the overlay leaving alone looks just like a
    /// cancel. The next press switches it back on with a fresh countdown, which the overlay itself confirms.
    @Test(arguments: [TimerPhase.counting, .paused, .ringing, .lingering])
    func aDoubleTapSwitchesTheToolOffAndTheNextPressBringsItBack(from phase: TimerPhase) {
        let harness = Harness()
        harness.model.hotkeys.showsConfirmation = true
        harness.timer.settings.durationSeconds = 10
        harness.model.handleHotkeyPress([.startTimer])
        harness.timerFakes.clock.time += 3
        switch phase {
        case .paused:
            harness.timer.pause()
        case .ringing, .lingering:
            harness.timerFakes.scheduler.fire(until: { harness.timer.phase == .ringing })
            if phase == .lingering {
                // A Preview replaces the alarm, which then counts as ended, so the overlay lingers after it.
                harness.timer.preview()
                harness.timer.stopPreview()
            }
        case .counting, .idle, .leaving:
            break
        }
        #expect(harness.timer.phase == phase && harness.timerFakes.presenter.isShowing)
        harness.timerFakes.clock.time += 1

        harness.model.handleHotkeyPress([.startTimer])
        harness.timerFakes.clock.time += 0.3
        harness.model.handleHotkeyPress([.startTimer])
        #expect(!harness.model.isOn(.timerOverlay) && !harness.timer.isEnabled)
        #expect(harness.model.status(of: .timerOverlay) == .off)
        #expect(harness.timer.phase == .idle && !harness.timerFakes.presenter.isShowing)
        #expect(!harness.timerFakes.alarm.isPlaying && harness.timerFakes.presenter.popOuts.count == 1)
        #expect(!harness.model.isPollingForTools, "nothing that needs Accessibility is on")
        #expect(harness.hotkeyHUD.lines == ["Timer Overlay off"], "the switch-off is confirmed over the game")
        #expect(harness.hotkeyHUD.presented.last?.sealed == true && harness.hotkeyHUD.presented.last?.displayID == 1)

        harness.timerFakes.clock.time += 1
        harness.model.handleHotkeyPress([.startTimer])
        #expect(harness.model.isOn(.timerOverlay) && harness.timer.isEnabled && harness.timer.phase == .counting)
        #expect(harness.timer.content.text == "00:10")
        #expect(harness.model.status(of: .timerOverlay) == .timer("0:10 left"))
        #expect(harness.timerFakes.presenter.popIns.count == 2)
        #expect(harness.hotkeyHUD.lines == ["Timer Overlay off"], "the countdown popping up confirms the switch back on")
    }

    /// The double tap's line joins the press's other changes, in order, like any hotkey's.
    @Test func aDoubleTapOnAKeyThatAlsoTogglesAToolSaysBoth() {
        let harness = Harness()
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true), .startTimer])
        #expect(harness.hotkeyHUD.lines == ["Crosshair on"])
        harness.timerFakes.clock.time += 0.25
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: false), .startTimer])
        #expect(harness.hotkeyHUD.lines == ["Crosshair on", "Crosshair off \u{00B7} Timer Overlay off"])
        #expect(harness.hotkeyHUD.presented.last?.sealed == true)
    }

    @Test func withShowConfirmationOffTheSwitchOffShowsNoLine() {
        let harness = Harness()
        harness.model.hotkeys.showsConfirmation = false
        harness.model.handleHotkeyPress([.startTimer])
        harness.timerFakes.clock.time += 0.25
        harness.model.handleHotkeyPress([.startTimer])
        #expect(!harness.model.isOn(.timerOverlay))
        #expect(harness.hotkeyHUD.presented.isEmpty)
    }

    /// The effect is what the press did to the switch: off only when the tool was on before it.
    @Test func theSwitchOffIsTheEffectOfTheSecondPress() {
        let harness = Harness()
        #expect(harness.model.handleHotkeyEvent(.startTimer) == nil)
        harness.timerFakes.clock.time += 0.25
        #expect(harness.model.handleHotkeyEvent(.startTimer) == .tool(.timerOverlay, isOn: false))
        #expect(harness.model.handleHotkeyEvent(.startTimerReleased) == nil, "a release while off changes nothing")
    }

    // The key driven through Hotkeys as real taps, with ducky's files, is in `TimerKeyTapTests`.

    @Test func holdingTheKeySwitchesTheToolOffToo() {
        let harness = Harness()
        harness.timer.settings.cancelGesture = .hold
        harness.model.handleHotkeyPress([.startTimer])
        harness.timerFakes.clock.time += 0.3
        harness.model.handleHotkeyPress([.startTimerReleased])
        #expect(harness.model.isOn(.timerOverlay), "a tap only starts")
        harness.timerFakes.clock.time += 2
        harness.model.handleHotkeyPress([.startTimer])
        harness.timerFakes.clock.time += 1.2
        harness.model.handleHotkeyPress([.startTimerReleased])
        #expect(!harness.model.isOn(.timerOverlay) && !harness.timer.isEnabled && harness.timer.phase == .idle)
        #expect(harness.hotkeyHUD.lines == ["Timer Overlay off"], "the release that switched it off says so")
        harness.timerFakes.clock.time += 1
        harness.model.handleHotkeyPress([.startTimer])
        #expect(harness.model.isOn(.timerOverlay) && harness.timer.phase == .counting)
    }

    @Test func pausingWithTheKeyKeepsTheToolOn() {
        let harness = Harness()
        harness.timer.settings.pressWhileCounting = .pauseOrResume
        harness.model.handleHotkeyPress([.startTimer])
        harness.timerFakes.clock.time += 2
        harness.model.handleHotkeyPress([.startTimer])
        #expect(harness.timer.phase == .paused && harness.model.isOn(.timerOverlay))
        #expect(harness.model.status(of: .timerOverlay) == .timer("Paused, 2:28"))
    }

    @Test func aReducedMotionThemeReachesTheOverlay() {
        // macOS's Reduce motion, which the app's watcher keeps in its theme even while the window is closed.
        let harness = Harness(theme: STTheme(systemReduceMotion: true))
        #expect(harness.model.theme.reduceMotion)
        harness.model.handleHotkeyEvent(.startTimer)
        #expect(!harness.timerFakes.presenter.popIns.isEmpty)
        #expect(harness.timerFakes.presenter.motions.allSatisfy { $0 })
    }

    @Test func reduceAnimationsInSettingsReachesTheOverlay() {
        let harness = Harness()
        harness.model.theme.motionMode = .reduced
        harness.model.handleHotkeyEvent(.startTimer)
        #expect(harness.timerFakes.presenter.popIns == [true])
    }

    @Test func fullMotionPopsInWithMotion() {
        let harness = Harness()
        harness.model.handleHotkeyEvent(.startTimer)
        #expect(harness.timerFakes.presenter.popIns == [false])
    }

    @Test func onAndIdleItHoldsNoPanelNoAlarmAndNoWake() {
        let harness = Harness()
        harness.model.setTool(.timerOverlay, on: true)
        #expect(!harness.timerFakes.presenter.isShowing)
        #expect(!harness.timerFakes.alarm.isPlaying)
        #expect(harness.timerFakes.scheduler.pending.isEmpty)
    }

    @Test func turningTheToolOffCancelsTheRun() {
        let harness = Harness()
        harness.model.handleHotkeyEvent(.startTimer)
        harness.model.setTool(.timerOverlay, on: false)
        #expect(harness.timer.phase != .counting)
        #expect(harness.model.status(of: .timerOverlay) == .off)
    }

    // MARK: - The Hotkey row

    @Test func theHotkeyRowFollowsTheHotkeyList() {
        let harness = Harness()
        let hotkeys = harness.model.hotkeys
        #expect(ToolHotkey.own(for: .startTimer, in: hotkeys.bindings) == nil)
        hotkeys.add(combo: HotkeyCombo(keyCode: 105, modifiers: []), actions: [.startTimer])
        #expect(ToolHotkey.own(for: .startTimer, in: hotkeys.bindings)?.combo.displayString == "F13")
    }

    // MARK: - Settings

    @Test func itsSettingsAreAKnownVersionAndResetWithTheTools() {
        #expect(AppModel.knownSettingsVersions[TimerOverlaySettings.name] == TimerOverlaySettings.version)
        let harness = Harness()
        harness.timer.settings.durationSeconds = 60
        harness.model.resetAllToolsToDefault()
        #expect(harness.timer.settings == TimerOverlaySettings.defaultValue)
    }

    // MARK: - The Dock

    @Test func theDockShowsNothingWhileItsSettingIsOff() {
        let harness = Harness()
        harness.model.handleHotkeyEvent(.startTimer)
        #expect(harness.model.timerDockBadge == nil)
        #expect(harness.model.timerDockItems.isEmpty)
    }

    @Test func theDockBadgeAndMenuFollowTheCountdown() {
        let harness = Harness()
        harness.timer.settings.showsDockCountdown = true
        #expect(harness.model.timerDockBadge == nil)
        #expect(harness.model.timerDockItems.map(\.action) == [.start])
        harness.model.performTimerDockItem(.start)
        #expect(harness.model.isOn(.timerOverlay))
        #expect(harness.model.timerDockBadge == "2:30")
        #expect(harness.model.timerDockItems.map(\.action) == [.start, .pause, .cancel])
        harness.model.performTimerDockItem(.pause)
        #expect(harness.timer.phase == .paused)
        #expect(harness.model.timerDockItems.map(\.action) == [.start, .resume, .cancel])
        harness.model.performTimerDockItem(.resume)
        #expect(harness.timer.phase == .counting)
        harness.model.performTimerDockItem(.cancel)
        #expect(harness.model.timerDockItems.map(\.action) == [.start])
    }

    @Test func theDockOffersNothingWithoutAccessibility() {
        let harness = Harness(accessibility: .denied)
        harness.timer.settings.showsDockCountdown = true
        #expect(harness.model.timerDockItems.isEmpty)
    }

    @Test func theBadgeWatcherHearsEachChange() async {
        let harness = Harness()
        harness.timer.settings.showsDockCountdown = true
        var badges: [String?] = []
        harness.model.watchTimerDockBadge { badges.append($0) }
        #expect(badges == [nil])
        harness.model.performTimerDockItem(.start)
        #expect(await waitUntil { badges.last == "2:30" })
    }
}

private extension FakeTimerScheduler {
    /// Fires the timer's wakes in time order, moving its clock forward to each, until `done` or none is left. A fired
    /// wake counts as cancelled, so it never fires twice.
    func fire(until done: () -> Bool) {
        while !done(), let next = pending.min(by: { $0.due < $1.due }) {
            next.isCancelled = true
            if let clock, clock.time < next.due { clock.time = next.due }
            next.action()
        }
    }
}
