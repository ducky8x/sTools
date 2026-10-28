import Foundation
import Prologue
import STPlatform
import Testing
@testable import sTools

@MainActor
@Suite("App ▸ Prologue")
struct AppModelPrologueTests {
    @Test func theFirstLaunchShowsTheIntroduction() {
        let harness = Harness(prologueCompleted: false)
        #expect(harness.model.prologue?.step == .greeting)
        #expect(harness.model.prologue?.showsSidebar == false)
    }

    @Test func laterLaunchesOpenAtHome() {
        let harness = Harness()
        #expect(harness.model.prologue == nil)
        #expect(harness.model.route == .home)
    }

    @Test func aLaunchMidwayResumesWhereItStopped() {
        let harness = Harness()
        harness.store.save(AppState(prologueCompleted: false, prologueStep: 6))
        harness.model.beginPrologue()
        #expect(harness.model.prologue?.step == .ninjabrainBot)
    }

    @Test func replayStartsFromTheGreeting() {
        let harness = Harness()
        harness.model.replayIntroduction()
        #expect(harness.model.prologue?.step == .greeting)
        #expect(harness.store.load(AppState.self) == AppState(prologueCompleted: false, prologueStep: 0))
    }

    @Test func goBackAndForwardDriveTheIntroduction() throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .camera)
        let prologue = try #require(harness.model.prologue)
        harness.model.perform(.back)
        #expect(prologue.step == .microphone)
        harness.model.perform(.forward)
        #expect(prologue.step == .camera)
        #expect(prologue.flow.skippedSteps == [.microphone])
        harness.model.perform(.settings)
        #expect(harness.model.prologue != nil)
        #expect(harness.model.route == .home)
    }

    @Test func openSToolsEndsAtHome() throws {
        let harness = Harness()
        harness.model.navigate(to: .settings)
        harness.model.beginPrologue(at: .openSTools)
        try #require(harness.model.prologue).next()
        #expect(harness.model.prologue == nil)
        #expect(harness.model.route == .home)
        #expect(!harness.model.canGoBack)
        #expect(harness.store.load(AppState.self).prologueCompleted)
    }

    @Test func theFinaleSwitchesOffOnlyWhatTheTrialsSwitchedOn() async throws {
        let harness = Harness()
        harness.model.setTool(.nbbOverlay, on: true)
        harness.model.beginPrologue(at: .youreSet)
        harness.model.setTool(.crosshair, on: true)
        harness.model.setTool(.windowBackdrop, on: true)
        #expect(harness.model.toolsToSwitchOff() == [.crosshair, .windowBackdrop], "in sidebar order")
        let prologue = try #require(harness.model.prologue)
        prologue.runFinale()
        prologue.completeFinale()
        #expect(!harness.model.isOn(.crosshair))
        #expect(!harness.model.isOn(.windowBackdrop))
        #expect(harness.model.isOn(.nbbOverlay))
    }

    @Test func everyToolHasItsTrial() {
        for tool in ToolID.allCases {
            let trial = tool.trial
            #expect(trial != nil)
            if let trial { #expect(ToolID(trial) == tool) }
        }
        #expect(ToolID.timerOverlay.trial == .timerOverlay)
    }

    @Test func theFinaleSwitchesTheTimerOff() throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .youreSet)
        harness.model.setTool(.timerOverlay, on: true)
        #expect(harness.model.toolsToSwitchOff() == [.timerOverlay])
        let prologue = try #require(harness.model.prologue)
        prologue.runFinale()
        prologue.completeFinale()
        #expect(!harness.model.isOn(.timerOverlay))
    }

    /// The trial's switch is the Timer page's, so it starts a countdown; the Finale's switch-off cancels it.
    @Test func theFinaleCancelsACountdownTheTrialsSwitchStarted() throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .timerTrial)
        harness.model.switchBinding(.timerOverlay).wrappedValue = true
        #expect(harness.timer.phase == .counting && harness.timerFakes.presenter.isShowing)
        let prologue = try #require(harness.model.prologue)
        prologue.runFinale()
        prologue.completeFinale()
        #expect(!harness.model.isOn(.timerOverlay) && harness.timer.phase == .idle)
        #expect(!harness.timerFakes.presenter.isShowing && harness.timerFakes.scheduler.pending.isEmpty)
    }

    @Test func aLaunchMidwaySavedByABuildWithoutTheTimerTrialResumesAtTheSameStep() async throws {
        let harness = Harness()
        await harness.store.flush()
        try Data(#"{"version":1,"value":{"prologueCompleted":false,"prologueStep":10}}"#.utf8)
            .write(to: harness.directory.appending(path: "appState.json"))
        harness.model.beginPrologue()
        #expect(harness.model.prologue?.step == .nbbOverlayTrial)
    }

    @Test func skippingTheIntroductionSwitchesTrialToolsOff() throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .crosshairTrial)
        harness.model.setTool(.crosshair, on: true)
        let prologue = try #require(harness.model.prologue)
        prologue.requestSkipIntroduction()
        prologue.confirmSkipIntroduction()
        #expect(harness.model.prologue == nil)
        #expect(!harness.model.isOn(.crosshair))
        #expect(harness.store.load(AppState.self).prologueCompleted)
    }
}
