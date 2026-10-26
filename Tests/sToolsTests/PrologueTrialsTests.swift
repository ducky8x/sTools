import Backdrop
import Crosshair
import Foundation
import NBBOverlay
import Prologue
import STDesign
import STPlatform
import Testing
import TimerOverlay
@testable import sTools

/// Holds the answer the fake Hotkeys question gives, so the test can change it after the closure captures it.
@MainActor
private final class AnswerBox {
    var value = false
}

@MainActor
@Suite("App ▸ Prologue trials")
struct PrologueTrialsTests {
    @Test func crosshairItemsTickAsTheSettingsChange() throws {
        let harness = Harness(usesRealControllers: true)
        harness.model.beginPrologue(at: .crosshairTrial)
        let crosshair = try #require(harness.model.controller(for: .crosshair, as: CrosshairController.self))
        let content = harness.model.trialContent(.crosshair)
        content.onAppear()
        #expect(content.completed().isEmpty)
        crosshair.settings.shape = .dot
        crosshair.settings.offsetX = 3
        #expect(content.completed() == ["shape", "offset"])
        crosshair.settings.fillHex = "#D9AE52"
        #expect(content.completed() == ["shape", "offset", "color"])
        content.onDisappear()
    }

    @Test func goingBackToATrialKeepsItsStartingPoint() throws {
        let harness = Harness(usesRealControllers: true)
        harness.model.beginPrologue(at: .crosshairTrial)
        let crosshair = try #require(harness.model.controller(for: .crosshair, as: CrosshairController.self))
        let content = harness.model.trialContent(.crosshair)
        content.onAppear()
        crosshair.settings.shape = .circle
        content.onDisappear()
        content.onAppear()
        #expect(content.completed() == ["shape"])
    }

    @Test func withoutAccessibilityTheSwitchItemCannotBeDone() {
        let harness = Harness(accessibility: .denied, usesRealControllers: true)
        harness.model.beginPrologue(at: .crosshairTrial)
        let item = harness.model.trialContent(.crosshair).items().first { $0.id == "on" }
        #expect(item?.unavailableReason == TrialCopy.needsAccessibility)
    }

    @Test func backdropFillChangesTick() throws {
        let harness = Harness(usesRealControllers: true)
        harness.model.beginPrologue(at: .backdropTrial)
        let backdrop = try #require(harness.model.controller(for: .windowBackdrop, as: BackdropController.self))
        let content = harness.model.trialContent(.windowBackdrop)
        content.onAppear()
        backdrop.settings.fill.color = "#2A241C"
        #expect(content.completed() == ["fill"])
        content.onDisappear()
        #expect(backdrop.standIn == nil)
    }

    @Test func theSampleResultIsAValidNinjabrainBotBody() throws {
        let sample = try #require(AppModel.sampleStronghold)
        #expect(sample.resultType == .triangulation)
        #expect(sample.predictions.count == 3)
        #expect(sample.eyeThrows.count == 2)
    }

    @Test func theNBBTrialShowsTheSampleOnlyWhileItShows() throws {
        let harness = Harness(usesRealControllers: true)
        harness.model.beginPrologue(at: .nbbOverlayTrial)
        let nbb = try #require(harness.model.controller(for: .nbbOverlay, as: NBBOverlayController.self))
        let content = harness.model.trialContent(.nbbOverlay)
        #expect(nbb.sample == nil)
        content.onAppear()
        #expect(nbb.sample != nil)
        #expect(content.items().first { $0.id == "measure" }?.unavailableReason == TrialCopy.NBB.sample)
        content.onDisappear()
        #expect(nbb.sample == nil)
    }

    @Test func skippingTheIntroductionClearsWhatTheTrialsSetUp() throws {
        let harness = Harness(usesRealControllers: true)
        harness.model.beginPrologue(at: .nbbOverlayTrial)
        let nbb = try #require(harness.model.controller(for: .nbbOverlay, as: NBBOverlayController.self))
        harness.model.trialContent(.nbbOverlay).onAppear()
        let prologue = try #require(harness.model.prologue)
        prologue.requestSkipIntroduction()
        prologue.confirmSkipIntroduction()
        #expect(nbb.sample == nil)
    }

    // MARK: Timer Overlay (spec 5.6.9)

    /// Fires the timer's held wakes in order, moving its fake clock along, for `seconds`.
    private func runTimer(_ fakes: TimerFakes, for seconds: TimeInterval) {
        let end = fakes.clock.time + seconds
        while let wake = fakes.scheduler.pending.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            fakes.clock.time = max(fakes.clock.time, wake.due)
            wake.cancel()
            wake.action()
        }
        fakes.clock.time = end
    }

    @Test func theTimerTrialSwitchesOnAndTicksWhenTheTestRunHasLeft() async throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .timerTrial)
        let timer = harness.timer
        let duration = timer.settings.durationSeconds
        let content = harness.model.trialContent(.timerOverlay)
        #expect(content.items().map(\.id) == ["on", "test", "place", "key"])
        content.onAppear()
        #expect(content.completed().isEmpty)
        // The trial keeps no timer of its own.
        #expect(harness.timerFakes.scheduler.pending.isEmpty)

        harness.model.setTool(.timerOverlay, on: true)
        #expect(content.completed() == ["on"])

        #expect(timer.runTest())
        #expect(await waitUntil { harness.model.trials.timerTestRunning })
        runTimer(harness.timerFakes, for: 3)
        #expect(timer.phase == .counting)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!content.completed().contains("test"))

        runTimer(harness.timerFakes, for: 120)
        #expect(timer.phase == .idle)
        #expect(await waitUntil { content.completed().contains("test") })
        #expect(timer.settings.durationSeconds == duration)
        content.onDisappear()
    }

    @Test func aRealCountdownStartedDuringTheTestDoesNotTickIt() async throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .timerTrial)
        let timer = harness.timer
        let content = harness.model.trialContent(.timerOverlay)
        content.onAppear()
        harness.model.setTool(.timerOverlay, on: true)
        #expect(timer.runTest())
        #expect(await waitUntil { harness.model.trials.timerTestRunning })
        #expect(timer.start())
        #expect(await waitUntil { !harness.model.trials.timerTestRunning })
        timer.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(timer.phase == .idle)
        #expect(!content.completed().contains("test"))
        content.onDisappear()
    }

    /// With Reduce animations the trial's Test run asks the overlay for no motion at all.
    @Test func theTimerTrialsTestRunHasNoMotionWithReduceAnimations() async throws {
        let harness = Harness(theme: STTheme(systemReduceMotion: true))
        harness.model.beginPrologue(at: .timerTrial)
        let content = harness.model.trialContent(.timerOverlay)
        content.onAppear()
        harness.model.setTool(.timerOverlay, on: true)
        #expect(harness.timer.runTest())
        #expect(await waitUntil { harness.model.trials.timerTestRunning })
        runTimer(harness.timerFakes, for: 120)
        #expect(harness.timer.phase == .idle)
        #expect(await waitUntil { content.completed().contains("test") })
        let presenter = harness.timerFakes.presenter
        #expect(!presenter.popIns.isEmpty)
        #expect(presenter.motions.allSatisfy { $0 })
        content.onDisappear()
    }

    @Test func draggingTheTimerTicksPlacement() throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .timerTrial)
        let content = harness.model.trialContent(.timerOverlay)
        content.onAppear()
        harness.timer.settings.offsetX += 12
        #expect(content.completed() == ["place"])
        content.onDisappear()
    }

    @Test func withoutAccessibilityTheTimerCannotBeSwitchedOnOrTested() {
        let harness = Harness(accessibility: .denied)
        harness.model.beginPrologue(at: .timerTrial)
        let items = harness.model.trialContent(.timerOverlay).items()
        #expect(items.first { $0.id == "on" }?.unavailableReason == TrialCopy.needsAccessibility)
        #expect(items.first { $0.id == "test" }?.unavailableReason == TrialCopy.needsAccessibility)
    }

    /// The trial's own recorder saves the key as a Home ▸ Hotkeys hotkey; while Hotkeys are off it asks first.
    @Test func aStartTimerKeyIsAHotkeyAndAsksWhileHotkeysAreOff() throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .timerTrial)
        harness.model.hotkeys.isEnabled = false
        let content = harness.model.trialContent(.timerOverlay)
        content.onAppear()
        var asked = 0
        let answer = AnswerBox()
        harness.model.confirmTurningOnHotkeys = {
            asked += 1
            return answer.value
        }
        let combo = HotkeyCombo(keyCode: 0x60, modifiers: [])

        TrialStartTimerKey.set(combo, in: harness.model)
        #expect(asked == 1)
        #expect(!harness.model.hotkeys.isEnabled)
        #expect(TrialStartTimerKey.own(in: harness.model.hotkeys.bindings) == nil)
        #expect(!content.completed().contains("key"))

        answer.value = true
        TrialStartTimerKey.set(combo, in: harness.model)
        #expect(asked == 2)
        #expect(harness.model.hotkeys.isEnabled)
        let own = try #require(TrialStartTimerKey.own(in: harness.model.hotkeys.bindings))
        #expect(own.actions == [.startTimer])
        #expect(own.combo == combo)
        #expect(content.completed().contains("key"))

        TrialStartTimerKey.set(nil, in: harness.model)
        #expect(TrialStartTimerKey.own(in: harness.model.hotkeys.bindings) == nil)
        #expect(asked == 2)
        content.onDisappear()
    }

    /// A Start-timer key that already exists when the trial opens (a new install's ⌘2) ticks the optional key item at
    /// once; it doesn't wait for the key to change. Clearing the key unticks it.
    @Test func anExistingStartTimerKeyTicksTheKeyItem() throws {
        let harness = Harness(hotkeys: nil)
        let own = try #require(TrialStartTimerKey.own(in: harness.model.hotkeys.bindings))
        #expect(own.combo == HotkeyCombo(keyCode: 19, modifiers: .command))
        harness.model.beginPrologue(at: .timerTrial)
        let content = harness.model.trialContent(.timerOverlay)
        content.onAppear()
        #expect(content.completed() == ["key"])

        TrialStartTimerKey.set(nil, in: harness.model)
        #expect(!content.completed().contains("key"))
        TrialStartTimerKey.set(HotkeyCombo(keyCode: 0x60, modifiers: []), in: harness.model)
        #expect(content.completed().contains("key"))
        content.onDisappear()
    }

    /// The trial names the key as the Timer page does: its row is Hotkey, its item says to set the tool's hotkey, and
    /// the question before turning Hotkeys on calls it Timer Overlay's hotkey. "Start-timer key" is gone from all three.
    @Test func theTimerTrialNamesItsKeyAsThePageDoes() {
        let harness = Harness()
        harness.model.beginPrologue(at: .timerTrial)
        let content = harness.model.trialContent(.timerOverlay)
        let item = content.items().first { $0.id == "key" }
        #expect(item?.title == "Set its hotkey")
        #expect(item?.isOptional == true)
        #expect(TrialStartTimerKeyRow.Copy.title == "Hotkey")
        #expect(TrialStartTimerKeyRow.Copy.recorderLabel == "Timer Overlay hotkey")
        #expect(AppModel.turnOnHotkeysText
            == "Hotkeys are off. Turn them on to set Timer Overlay\u{2019}s key.")
        let words = [item?.title ?? "", item?.detail ?? "", TrialStartTimerKeyRow.Copy.title, AppModel.turnOnHotkeysText]
        #expect(!words.contains { $0.localizedCaseInsensitiveContains("start-timer key") })
    }

    /// A key that starts the timer together with something else counts too.
    @Test func aSharedStartTimerKeyTicksTheKeyItem() {
        let harness = Harness()
        harness.model.beginPrologue(at: .timerTrial)
        _ = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 0x61, modifiers: []),
                                      actions: [.toggle(.crosshair), .startTimer])
        let content = harness.model.trialContent(.timerOverlay)
        content.onAppear()
        #expect(content.completed() == ["key"])
        content.onDisappear()
    }

    @Test func replayStartsTheTrialsAfresh() throws {
        let harness = Harness(usesRealControllers: true)
        harness.model.beginPrologue(at: .crosshairTrial)
        let crosshair = try #require(harness.model.controller(for: .crosshair, as: CrosshairController.self))
        harness.model.trialContent(.crosshair).onAppear()
        crosshair.settings.shape = .x
        harness.model.replayIntroduction()
        let content = harness.model.trialContent(.crosshair)
        content.onAppear()
        #expect(content.completed().isEmpty)
    }
}
