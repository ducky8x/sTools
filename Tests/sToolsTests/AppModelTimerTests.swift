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

    // MARK: - Set in Hotkeys…

    @Test func setInHotkeysOpensHomesHotkeysWithANewStartTimerHotkey() {
        let harness = Harness()
        harness.model.hotkeys.isEnabled = true
        var asked = false
        harness.model.confirmTurningOnHotkeys = { asked = true; return true }
        harness.model.navigate(to: .tool(.timerOverlay))
        harness.model.openHotkeysForStartTimer()
        #expect(!asked)
        #expect(harness.model.route == .home)
        #expect(harness.model.pendingPageAnchor == .hotkeys)
        #expect(harness.model.pendingNewHotkeyActions == [.startTimer])
    }

    @Test func setInHotkeysAsksBeforeTurningHotkeysOn() {
        let harness = Harness()
        harness.model.hotkeys.isEnabled = false
        harness.model.confirmTurningOnHotkeys = { true }
        harness.model.openHotkeysForStartTimer()
        #expect(harness.model.hotkeys.isEnabled)
        #expect(harness.model.pendingNewHotkeyActions == [.startTimer])
    }

    @Test func decliningOpensHotkeysWithoutANewOne() {
        let harness = Harness()
        harness.model.hotkeys.isEnabled = false
        harness.model.confirmTurningOnHotkeys = { false }
        harness.model.navigate(to: .tool(.timerOverlay))
        harness.model.openHotkeysForStartTimer()
        #expect(!harness.model.hotkeys.isEnabled)
        #expect(harness.model.pendingNewHotkeyActions == nil)
        #expect(harness.model.route == .home)
        #expect(harness.model.pendingPageAnchor == .hotkeys)
    }

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
