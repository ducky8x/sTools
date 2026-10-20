import Backdrop
import Crosshair
import NBBOverlay
import Prologue
import Testing
@testable import sTools

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
