import STPlatform
import Testing
@testable import Prologue

@Suite("Prologue flow")
struct PrologueFlowTests {
    @Test func hasSixteenStepsInFourParts() {
        #expect(PrologueStep.count == 16)
        let parts = Dictionary(grouping: PrologueStep.allCases, by: \.part).mapValues(\.count)
        #expect(parts == [.welcome: 1, .preparations: 7, .trials: 6, .finale: 2])
        #expect(PrologueStep.greeting.number == 1)
        #expect(PrologueStep.openSTools.number == 16)
    }

    /// The Timer trial is step 10, after Crosshair's, at the index `AppState` moves old saved steps across.
    @Test func theTimerTrialIsStepTen() {
        #expect(PrologueStep.timerTrial.number == 10)
        #expect(PrologueStep.timerTrial.rawValue == AppState.timerTrialIndex)
        #expect(PrologueStep.timerTrial.trial == .timerOverlay)
        #expect(PrologueStep.timerTrial.part == .trials)
        #expect(PrologueStep.allCases.compactMap(\.trial) == PrologueTrial.allCases)
    }

    /// The Trials are shown in sidebar order (revision 12), while each step keeps the index saved progress names it by.
    @Test func theTrialsFollowTheSidebarAndKeepTheirSavedIndices() {
        #expect(PrologueTrial.allCases == [.crosshair, .timerOverlay, .nbbOverlay, .screenRecording, .windowBackdrop, .keyRebinder])
        #expect(PrologueStep.allCases.compactMap(\.trial) == PrologueTrial.allCases)
        #expect([PrologueStep.crosshairTrial, .timerTrial, .nbbOverlayTrial, .recordingTrial, .backdropTrial, .keyRebinderTrial]
            .map(\.number) == [9, 10, 11, 12, 13, 14])
        // The saved indices are the ones every earlier build wrote.
        #expect(PrologueStep.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 10, 13, 14, 15])
        #expect(PrologueStep.backdropTrial.rawValue == AppState.backdropTrialIndex)
        #expect(PrologueStep.nbbOverlayTrial.rawValue == AppState.nbbOverlayTrialIndex)
        #expect(Set(PrologueStep.allCases.map(\.rawValue)) == Set(0..<16))
    }

    /// A step saved by a build that showed the old trial order (Crosshair, Timer Overlay, Window Backdrop, NBB
    /// Overlay, Screen Recording, Key Rebinder) resumes where Continue still reaches every step that build hadn't
    /// shown yet, and at the saved step itself wherever that's so.
    @Test(arguments: 0..<16)
    func aStepSavedInTheOldTrialOrderLeavesNoTrialUnseen(saved: Int) {
        let oldOrder = (0..<16).map { PrologueStep(savedIndex: $0) }
        let notYetShown = Set(oldOrder.drop { $0.rawValue != saved })
        var flow = PrologueFlow(resumingAt: AppState.step(fromOldTrialOrder: saved))
        var reached: Set<PrologueStep> = [flow.step]
        while flow.next(), !flow.isEnded { reached.insert(flow.step) }
        #expect(notYetShown.isSubset(of: reached))
        if saved != AppState.backdropTrialIndex {
            #expect(AppState.step(fromOldTrialOrder: saved) == saved)
        }
    }

    @Test func startsAtTheGreeting() {
        let flow = PrologueFlow()
        #expect(flow.step == .greeting)
        #expect(!flow.canGoBack)
        #expect(flow.outcome == nil)
    }

    @Test(arguments: [0, 3, 9, 10, 11, 12, 14, 15])
    func resumesAtASavedStep(index: Int) {
        #expect(PrologueFlow(resumingAt: index).step.rawValue == index)
    }

    /// Continue and Back follow the order shown, not the saved indices: NBB Overlay's trial follows the Timer trial.
    @Test func continueAndBackFollowTheOrderShown() {
        var flow = PrologueFlow(resumingAt: PrologueStep.timerTrial.rawValue)
        var shown: [PrologueStep] = []
        for _ in 0..<4 {
            flow.next()
            shown.append(flow.step)
        }
        #expect(shown == [.nbbOverlayTrial, .recordingTrial, .backdropTrial, .keyRebinderTrial])
        flow.back()
        #expect(flow.step == .backdropTrial)
        flow.back()
        #expect(flow.step == .recordingTrial)
        #expect(flow.progress == Double(12) / 16)
    }

    @Test(arguments: [-1, 16, 99])
    func anUnknownSavedStepStartsAtTheGreeting(index: Int) {
        #expect(PrologueFlow(resumingAt: index).step == .greeting)
    }

    @Test func continueWalksEveryStepThenFinishes() {
        var flow = PrologueFlow()
        var seen = [flow.step]
        while flow.next(), !flow.isEnded { seen.append(flow.step) }
        #expect(seen == PrologueStep.allCases)
        #expect(flow.outcome == .finished)
        let result1 = flow.next()
        #expect(!result1)
    }

    @Test func backGoesAllTheWayToTheGreetingAndNoFurther() {
        var flow = PrologueFlow(resumingAt: 4)
        for expected in [3, 2, 1, 0] {
            let result2 = flow.back()
            #expect(result2)
            #expect(flow.step.rawValue == expected)
            #expect(flow.direction == .backward)
        }
        let result3 = flow.back()
        #expect(!result3)
        #expect(flow.step == .greeting)
    }

    @Test func pagesTurnForwardAndBack() {
        var flow = PrologueFlow(resumingAt: 5)
        flow.next()
        #expect(flow.direction == .forward)
        flow.back()
        #expect(flow.direction == .backward)
        flow.skipStep()
        #expect(flow.direction == .forward)
    }

    @Test func everyPageTurnIsANewVisit() {
        var flow = PrologueFlow(resumingAt: 2)
        flow.next()
        flow.back()
        flow.next()
        #expect(flow.step.rawValue == 3)
        #expect(flow.visit == 3)
    }

    @Test func skipStepMovesOnAndRemembersTheSkip() {
        var flow = PrologueFlow(resumingAt: 2)
        let result4 = flow.skipStep()
        #expect(result4)
        #expect(flow.step.rawValue == 3)
        #expect(flow.skippedSteps == [PrologueStep(savedIndex: 2)])
        flow.back()
        flow.next()
        #expect(flow.skippedSteps.isEmpty)
    }

    @Test func skippingTheLastStepFinishes() {
        var flow = PrologueFlow(resumingAt: PrologueStep.openSTools.rawValue)
        flow.skipStep()
        #expect(flow.outcome == .finished)
    }

    @Test func skippingTheIntroductionAsksFirst() {
        var flow = PrologueFlow(resumingAt: 6)
        flow.requestSkipIntroduction()
        #expect(flow.isConfirmingSkip)
        #expect(flow.outcome == nil)
        // While it asks, nothing else moves.
        let result5 = flow.next()
        #expect(!result5)
        let result6 = flow.back()
        #expect(!result6)
        let result7 = flow.skipStep()
        #expect(!result7)
        #expect(flow.step.rawValue == 6)
        flow.confirmSkipIntroduction()
        #expect(flow.outcome == .skipped)
        #expect(!flow.isConfirmingSkip)
    }

    @Test func keepGoingReturnsToTheSameStep() {
        var flow = PrologueFlow(resumingAt: 9)
        flow.requestSkipIntroduction()
        flow.cancelSkipIntroduction()
        #expect(!flow.isConfirmingSkip)
        #expect(flow.outcome == nil)
        #expect(flow.step.rawValue == 9)
        let result8 = flow.next()
        #expect(result8)
    }

    @Test func confirmingWithoutAskingDoesNothing() {
        var flow = PrologueFlow(resumingAt: 3)
        flow.confirmSkipIntroduction()
        #expect(flow.outcome == nil)
    }

    @Test func skipIsOfferedFromTheGreetingToo() {
        var flow = PrologueFlow()
        flow.requestSkipIntroduction()
        flow.confirmSkipIntroduction()
        #expect(flow.outcome == .skipped)
    }

    @Test func replayStartsOverFromTheGreeting() {
        var flow = PrologueFlow(resumingAt: 11)
        flow.skipStep()
        flow.requestSkipIntroduction()
        flow.confirmSkipIntroduction()
        flow.restart()
        #expect(flow == PrologueFlow())
    }

    @Test func progressFillsASixteenthPerStep() {
        #expect(PrologueFlow().progress == 1.0 / 16)
        #expect(PrologueFlow(resumingAt: 15).progress == 1)
    }

    @Test func stepsKnowWhatTheySetUp() {
        #expect(PrologueStep.accessibility.permission == .accessibility)
        #expect(PrologueStep.camera.permission == .camera)
        #expect(PrologueStep.ninjabrainBot.companion == .ninjabrainBot)
        #expect(PrologueStep.karabiner.companion == .karabiner)
        #expect(PrologueStep.allCases.compactMap(\.trial) == PrologueTrial.allCases)
        #expect(PrologueStep.allCases.compactMap(\.permission).count == 5)
    }
}
