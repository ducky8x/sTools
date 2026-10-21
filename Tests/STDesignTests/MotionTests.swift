import SwiftUI
import Testing
@testable import STDesign

@Test func animationTokensMatchSpec() {
    #expect(STMotion.press == .easeOut(duration: 0.10))
    #expect(STMotion.quick == .spring(response: 0.26, dampingFraction: 0.82))
    #expect(STMotion.standard == .spring(response: 0.40, dampingFraction: 0.86))
    #expect(STMotion.page == .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.50))
}

@Test func durationTokensMatchSpec() {
    #expect(STMotion.typeInterval == .milliseconds(18))
    #expect(STMotion.ceremony == .seconds(4))
    #expect(STMotion.staggerInterval == .milliseconds(35))
    #expect(STMotion.staggerMax == 10)
}

@Test(arguments: [STMotion.press, STMotion.quick, STMotion.standard, STMotion.page, STTypingMotion.settle, STTypingMotion.shake])
func resolveGivesNoAnimationWhileMotionIsReduced(animation: Animation) {
    #expect(STMotion.resolve(animation, reduce: true) == nil)
    #expect(STMotion.resolve(animation, reduce: false) == animation)
}

@Test func theInstantTransactionTurnsEveryAnimationOff() {
    let transaction = STMotion.instant
    #expect(transaction.animation == nil)
    #expect(transaction.disablesAnimations)
}

@MainActor
@Test(arguments: [true, false])
func animateRunsTheChangesOnceAndReturnsTheirResult(reduce: Bool) {
    var runs = 0
    let result = STMotion.animate(STMotion.quick, reduce: reduce) { () -> Int in
        runs += 1
        return 42
    }
    #expect(runs == 1)
    #expect(result == 42)
}

@MainActor
@Test func whileReducedTheCompletionRunsAtOnceAfterTheChanges() {
    var order: [String] = []
    STMotion.animate(STMotion.page, reduce: true) {
        order.append("changes")
    } completion: {
        order.append("completion")
    }
    #expect(order == ["changes", "completion"])
}

@MainActor
@Test func stAnimationAndTheMotionRootBuildForBothThemes() {
    let reduced = STTheme(motionMode: .reduced)
    let full = STTheme()
    #expect(STMotion.resolve(STMotion.page, reduce: reduced.reduceMotion) == nil)
    #expect(STMotion.resolve(STMotion.page, reduce: full.reduceMotion) == STMotion.page)
    _ = Text("x").stAnimation(STMotion.quick, value: 1).environment(\.stTheme, reduced)
    _ = Text("x").stMotionRoot(reduced)
}
