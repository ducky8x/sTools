import Testing
@testable import Prologue

@Suite("Prologue flow")
struct PrologueFlowTests {
    @Test func hasFifteenStepsInFourParts() {
        #expect(PrologueStep.count == 15)
        let parts = Dictionary(grouping: PrologueStep.allCases, by: \.part).mapValues(\.count)
        #expect(parts == [.welcome: 1, .preparations: 7, .trials: 5, .finale: 2])
        #expect(PrologueStep.greeting.number == 1)
        #expect(PrologueStep.openSTools.number == 15)
    }

    @Test func startsAtTheGreeting() {
        let flow = PrologueFlow()
        #expect(flow.step == .greeting)
        #expect(!flow.canGoBack)
        #expect(flow.outcome == nil)
    }

    @Test(arguments: [0, 3, 9, 14])
    func resumesAtASavedStep(index: Int) {
        #expect(PrologueFlow(resumingAt: index).step.rawValue == index)
    }

    @Test(arguments: [-1, 15, 99])
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
        var flow = PrologueFlow(resumingAt: 14)
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

    @Test func progressFillsAFifteenthPerStep() {
        #expect(PrologueFlow().progress == 1.0 / 15)
        #expect(PrologueFlow(resumingAt: 14).progress == 1)
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
