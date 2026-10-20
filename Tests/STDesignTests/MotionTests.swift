import SwiftUI
import Testing
@testable import STDesign

@Test func animationTokensMatchSpec() {
    #expect(STMotion.press == .easeOut(duration: 0.10))
    #expect(STMotion.quick == .spring(response: 0.26, dampingFraction: 0.82))
    #expect(STMotion.standard == .spring(response: 0.40, dampingFraction: 0.86))
    #expect(STMotion.page == .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.50))
    #expect(STMotion.reducedFade == .easeInOut(duration: 0.2))
}

@Test func durationTokensMatchSpec() {
    #expect(STMotion.typeInterval == .milliseconds(18))
    #expect(STMotion.ceremony == .seconds(4))
    #expect(STMotion.staggerInterval == .milliseconds(35))
    #expect(STMotion.staggerMax == 10)
}

@Test(arguments: [STMotion.press, STMotion.quick, STMotion.standard, STMotion.page, STMotion.reducedFade])
func resolveHonorsReduceMotion(animation: Animation) {
    #expect(STMotion.resolve(animation, reduce: true) == STMotion.reducedFade)
    #expect(STMotion.resolve(animation, reduce: false) == animation)
}

@MainActor
@Test func stAnimationBuildsForBothThemes() {
    let reduced = STTheme(motionMode: .reduced)
    let full = STTheme()
    #expect(STMotion.resolve(STMotion.page, reduce: reduced.reduceMotion) == STMotion.reducedFade)
    #expect(STMotion.resolve(STMotion.page, reduce: full.reduceMotion) == STMotion.page)
    _ = Text("x").stAnimation(STMotion.quick, value: 1).environment(\.stTheme, reduced)
}
