import Foundation
import STPlatform
import Testing
@testable import Prologue

@MainActor
@Suite("Prologue model")
struct PrologueModelTests {
    private func makeModel(_ box: StoreBox, host: FakeHost, at step: PrologueStep? = nil) -> PrologueModel {
        PrologueModel(store: box.store, host: host, startingAt: step, finaleDelay: .zero, finaleInterval: .milliseconds(1))
    }

    @Test func isNeededUntilFinishedOrSkipped() {
        let box = StoreBox()
        #expect(PrologueModel.isNeeded(in: box.store))
        box.store.save(AppState(prologueCompleted: true))
        #expect(!PrologueModel.isNeeded(in: box.store))
    }

    @Test func savesItsPlaceAfterEveryStep() async {
        let box = StoreBox()
        let host = FakeHost()
        let model = makeModel(box, host: host)
        model.next()
        model.next()
        model.skipStep()
        #expect(box.store.load(AppState.self) == AppState(prologueCompleted: false, prologueStep: 3))
        model.back()
        #expect(box.store.load(AppState.self).prologueStep == 2)
        await box.store.flush()
        #expect(box.reopened().load(AppState.self).prologueStep == 2)
    }

    @Test func resumesAfterQuittingAtTheSameStep() async {
        let box = StoreBox()
        let first = makeModel(box, host: FakeHost())
        for _ in 0..<9 { first.next() }
        await box.store.flush()

        let relaunched = PrologueModel(store: box.reopened(), host: FakeHost())
        #expect(relaunched.step == .timerTrial)
    }

    /// A build from before the Timer trial saved its NBB Overlay trial as index 10; it resumes there, now step 11.
    @Test func resumesAtTheSameStepSavedByABuildWithoutTheTimerTrial() async throws {
        let box = StoreBox()
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let url = box.directory.appending(path: "appState.json")
        try Data(#"{"version":1,"value":{"prologueCompleted":false,"prologueStep":10}}"#.utf8).write(to: url)
        let model = PrologueModel(store: box.reopened(), host: FakeHost())
        #expect(model.step == .nbbOverlayTrial)
        #expect(model.step.number == 11)
    }

    /// A build that showed Window Backdrop's trial before NBB Overlay's saved it (index 10) without
    /// `trialsInSidebarOrder`; it resumes at NBB Overlay's trial, so NBB Overlay and Screen Recording aren't skipped,
    /// and Window Backdrop's follows them.
    @Test func aBackdropTrialSavedInTheOldOrderResumesAtNBBOverlaysTrial() async throws {
        let box = StoreBox()
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let url = box.directory.appending(path: "appState.json")
        try Data(#"{"version":1,"value":{"prologueCompleted":false,"prologueStep":9,"prologueStepWithTimerTrial":10}}"#.utf8)
            .write(to: url)
        let model = PrologueModel(store: box.reopened(), host: FakeHost())
        #expect(model.step == .nbbOverlayTrial)
        model.next()
        model.next()
        #expect(model.step == .backdropTrial)
    }

    /// Today's builds save Window Backdrop's trial with `trialsInSidebarOrder`, so it resumes right there.
    @Test func aBackdropTrialSavedInSidebarOrderResumesThere() async {
        let box = StoreBox()
        let first = makeModel(box, host: FakeHost(), at: .backdropTrial)
        #expect(first.step.number == 13)
        await box.store.flush()
        let relaunched = PrologueModel(store: box.reopened(), host: FakeHost())
        #expect(relaunched.step == .backdropTrial)
    }

    @Test func replayStartsAtTheGreetingWhateverWasSaved() {
        let box = StoreBox()
        box.store.save(AppState(prologueCompleted: true, prologueStep: 0))
        let model = makeModel(box, host: FakeHost(), at: .greeting)
        #expect(model.step == .greeting)
        #expect(box.store.load(AppState.self) == AppState(prologueCompleted: false, prologueStep: 0))
    }

    @Test func finishingIsSavedAndReported() {
        let box = StoreBox()
        let host = FakeHost()
        let model = makeModel(box, host: host, at: .openSTools)
        model.next()
        #expect(host.outcomes == [.finished])
        #expect(box.store.load(AppState.self) == AppState(prologueCompleted: true, prologueStep: 0))
        #expect(!PrologueModel.isNeeded(in: box.store))
    }

    @Test func skippingTheIntroductionAsksThenEnds() {
        let box = StoreBox()
        let host = FakeHost()
        let model = makeModel(box, host: host, at: .microphone)
        model.requestSkipIntroduction()
        #expect(model.flow.isConfirmingSkip)
        #expect(host.outcomes.isEmpty)
        model.cancelSkipIntroduction()
        #expect(model.step == .microphone)
        model.requestSkipIntroduction()
        model.confirmSkipIntroduction()
        #expect(host.outcomes == [.skipped])
        #expect(box.store.load(AppState.self).prologueCompleted)
    }

    @Test func goingBackNeverUndoesAnything() async {
        let box = StoreBox()
        let host = FakeHost()
        host.prober.set(.accessibility, .granted)
        let model = makeModel(box, host: host, at: .crosshairTrial)
        let items = [ChecklistItem(id: "on", title: "Switch it on")]
        model.record(done: ["on"], items: items, for: .crosshair)
        model.back()
        model.back()
        model.next()
        model.next()
        #expect(model.checklist(for: .crosshair, items: items).state(of: "on") == .done)
        #expect(model.status(of: .accessibility) == .granted)
        #expect(host.prober.requested.isEmpty)
    }

    @Test func checklistTicksAreReportedOnce() {
        let model = makeModel(StoreBox(), host: FakeHost(), at: .keyRebinderTrial)
        let items = [ChecklistItem(id: "layout", title: "Pick your keyboard layout"), ChecklistItem(id: "menu", title: "Open the profile menu")]
        #expect(model.record(done: ["layout"], items: items, for: .keyRebinder) == ["layout"])
        #expect(model.record(done: ["layout"], items: items, for: .keyRebinder).isEmpty)
        model.skipItem("menu", items: items, in: .keyRebinder)
        #expect(model.checklist(for: .keyRebinder, items: items).isComplete)
    }

    // MARK: Preparations

    @Test func allowAsksMacOSWhenItStillCan() async {
        let host = FakeHost()
        host.prober.grantOnRequest(.microphone)
        let model = makeModel(StoreBox(), host: host, at: .microphone)
        await model.allow(.microphone)
        #expect(host.prober.requested == [.microphone])
        #expect(model.status(of: .microphone) == .granted)
        #expect(host.openedURLs.isEmpty)
    }

    @Test func allowOpensSystemSettingsOnceMacOSWontAskAgain() async {
        let host = FakeHost()
        host.prober.set(.camera, .denied)
        let model = makeModel(StoreBox(), host: host, at: .camera)
        await model.allow(.camera)
        #expect(host.prober.requested.isEmpty)
        #expect(host.openedURLs == [Permission.camera.settingsURL])
    }

    @Test func allowAccessibilityFallsBackToItsPane() async {
        let host = FakeHost()
        host.prober.set(.accessibility, .denied)
        let model = makeModel(StoreBox(), host: host, at: .accessibility)
        await model.allow(.accessibility)
        #expect(host.prober.requested == [.accessibility])
        #expect(host.openedURLs == [Permission.accessibility.settingsURL])
    }

    @Test func screenRecordingOffersARelaunchAfterAllow() async {
        let host = FakeHost()
        host.prober.set(.screenRecording, .denied)
        let model = makeModel(StoreBox(), host: host, at: .screenRecording)
        #expect(model.relaunchOffered.isEmpty)
        await model.allow(.screenRecording)
        #expect(model.relaunchOffered == [.screenRecording])
        model.relaunch()
        #expect(host.relaunches == 1)
    }

    @Test func companionStatusComesFromTheHost() async {
        let host = FakeHost()
        host.companionStatuses[.karabiner] = .ready
        let model = makeModel(StoreBox(), host: host, at: .karabiner)
        await model.refresh(.karabiner)
        await model.refresh(.ninjabrainBot)
        #expect(model.companionStatuses[.karabiner] == .ready)
        #expect(model.companionStatuses[.ninjabrainBot]?.isReady == false)
        model.performAction(for: .karabiner)
        #expect(host.performedActions == [.karabiner])
    }

    @Test func theLeavingPageDoesNotStopTheArrivingPagesCheck() async {
        let host = FakeHost()
        host.companionStatuses[.karabiner] = .ready
        let model = makeModel(StoreBox(), host: host, at: .ninjabrainBot)
        model.startWatching(.ninjabrainBot)
        model.next()
        model.startWatching(.karabiner)
        model.stopWatching(.ninjabrainBot)
        #expect(await waitUntil { model.companionStatuses[.karabiner] == .ready })
        model.stopWatching(.karabiner)
    }

    @Test func showingAPermissionStepReadsItsStatusAtOnce() {
        let host = FakeHost()
        let model = makeModel(StoreBox(), host: host, at: .accessibility)
        #expect(model.status(of: .accessibility) == .notDetermined)
        host.prober.set(.accessibility, .granted)
        model.startPollingPermissions()
        model.startPollingPermissions()
        #expect(model.status(of: .accessibility) == .granted)
        model.stopPollingPermissions()
        model.stopPollingPermissions()
    }

    // MARK: Finale

    @Test func theFinaleSwitchesToolsOffInTurn() async {
        let host = FakeHost()
        host.toolsOn = [.nbbOverlay, .crosshair, .screenRecording]
        let model = makeModel(StoreBox(), host: host, at: .youreSet)
        model.runFinale()
        #expect(await waitUntil { host.toolsOn.isEmpty })
        #expect(host.switchedOff == [.nbbOverlay, .crosshair, .screenRecording])
        #expect(model.finaleSwitchedOff == host.switchedOff)
    }

    @Test func aClickFinishesTheFinaleAtOnce() {
        let host = FakeHost()
        host.toolsOn = [.windowBackdrop, .crosshair]
        let model = PrologueModel(store: StoreBox().store, host: host, startingAt: .youreSet,
                                  finaleDelay: .seconds(60), finaleInterval: .seconds(60))
        model.runFinale()
        #expect(host.switchedOff.isEmpty)
        model.completeFinale()
        #expect(host.switchedOff == [.windowBackdrop, .crosshair])
        #expect(!model.isFinaleRunning)
    }

    @Test func leavingTheFinaleFinishesItsSwitchOffs() {
        let host = FakeHost()
        host.toolsOn = [.crosshair]
        let model = PrologueModel(store: StoreBox().store, host: host, startingAt: .youreSet,
                                  finaleDelay: .seconds(60), finaleInterval: .seconds(60))
        model.runFinale()
        model.next()
        #expect(host.switchedOff == [.crosshair])
        #expect(model.step == .openSTools)
    }

    @Test func theSidebarReturnsForTheFinale() {
        let model = makeModel(StoreBox(), host: FakeHost(), at: .keyRebinderTrial)
        #expect(!model.showsSidebar)
        model.next()
        #expect(model.showsSidebar)
    }

    // MARK: Animations

    @Test func anyInputCompletesOnlyWhatIsPlaying() {
        var clock = ContinuousClock.now
        let animations = PrologueAnimations(now: { clock })
        #expect(!animations.completeAll())
        animations.run(for: .seconds(1))
        #expect(animations.isRunning)
        #expect(animations.completeAll())
        #expect(animations.completionCount == 1)
        #expect(!animations.isRunning)
        animations.run(for: .seconds(1))
        clock = clock.advanced(by: .seconds(2))
        #expect(!animations.isRunning)
        #expect(!animations.completeAll())
    }

    @Test func aNewPageStartsStill() {
        let model = makeModel(StoreBox(), host: FakeHost(), at: .camera)
        model.animations.run(for: .seconds(5))
        model.next()
        #expect(!model.animations.isRunning)
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = SuspendingClock.now + timeout
    while !condition() {
        if SuspendingClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
