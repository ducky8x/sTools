import CoreGraphics
import STDesign
import SwiftUI
import Testing
@testable import TimerOverlay

private let rest = TimerMotion.Pose.rest

@Suite("Timer motion")
struct TimerMotionTests {
    // MARK: Pop-in and pop-out, full motion

    @Test(arguments: [Edge.top, .bottom, .leading, .trailing])
    func springPopScalesUpFromNinetyPercentWhileFadingIn(edge: Edge) {
        let popIn = TimerMotion.popIn(.springPop, from: edge, reduceMotion: false)
        #expect(popIn.from == TimerMotion.Pose(scale: 0.9, opacity: 0))
        #expect(popIn.to == rest)
        #expect(popIn.animation == STMotion.quick)
        #expect(popIn.duration > 0.2 && popIn.duration < 0.5, "about a quarter second")

        let popOut = TimerMotion.popOut(.springPop, toward: edge, reduceMotion: false)
        #expect(popOut.from == rest)
        #expect(popOut.to == TimerMotion.Pose(scale: 0.9, opacity: 0), "it leaves the way it came, reversed")
        #expect(popOut.animation == STMotion.quick)
    }

    @Test(arguments: [Edge.top, .bottom, .leading, .trailing])
    func fadeOnlyChangesOpacity(edge: Edge) {
        let popIn = TimerMotion.popIn(.fade, from: edge, reduceMotion: false)
        #expect(popIn.from == TimerMotion.Pose(opacity: 0))
        #expect(popIn.to == rest)
        #expect(popIn.animation == STMotion.quick)

        let popOut = TimerMotion.popOut(.fade, toward: edge, reduceMotion: false)
        #expect(popOut.from == rest)
        #expect(popOut.to == TimerMotion.Pose(opacity: 0))
        #expect(popOut.animation == STMotion.quick)
    }

    @Test(arguments: [
        (Edge.top, CGSize(width: 0, height: -24)), (.bottom, CGSize(width: 0, height: 24)),
        (.leading, CGSize(width: -24, height: 0)), (.trailing, CGSize(width: 24, height: 0)),
    ])
    func slideComesInFromTheNearestEdgeAndLeavesTowardIt(edge: Edge, offset: CGSize) {
        let popIn = TimerMotion.popIn(.slide, from: edge, reduceMotion: false)
        #expect(popIn.from == TimerMotion.Pose(offset: offset, opacity: 0))
        #expect(popIn.to == rest)
        #expect(popIn.animation == STMotion.standard)

        let popOut = TimerMotion.popOut(.slide, toward: edge, reduceMotion: false)
        #expect(popOut.from == rest)
        #expect(popOut.to == TimerMotion.Pose(offset: offset, opacity: 0))
        #expect(popOut.animation == STMotion.standard)
    }

    @Test func noneIsStillAndAtOnce() {
        let popIn = TimerMotion.popIn(.instant, from: .top, reduceMotion: false)
        #expect(popIn.isStill)
        #expect(popIn.from == rest && popIn.to == rest)
        #expect(popIn.animation == nil)
        #expect(popIn.duration == 0)
        let popOut = TimerMotion.popOut(.instant, toward: .top, reduceMotion: false)
        #expect(popOut.isStill)
        #expect(popOut.animation == nil)
    }

    // MARK: Pop-in and pop-out, reduced

    /// Under Reduce animations (or macOS's Reduce motion) the overlay appears and leaves at once in every Pop-up motion
    /// (spec 5.6.4): scale stays 1, the offset 0, and there's no opacity ramp.
    @Test(arguments: TimerOverlaySettings.PopUpMotion.allCases, [Edge.top, .bottom, .leading, .trailing])
    func reducedMotionAppearsAndLeavesAtOnce(motion: TimerOverlaySettings.PopUpMotion, edge: Edge) {
        for step in [TimerMotion.popIn(motion, from: edge, reduceMotion: true),
                     TimerMotion.popOut(motion, toward: edge, reduceMotion: true)] {
            #expect(step.from == rest)
            #expect(step.to == rest)
            #expect(step.from.scale == 1 && step.to.scale == 1)
            #expect(step.from.offset == .zero && step.to.offset == .zero)
            #expect(step.from.opacity == 1 && step.to.opacity == 1, "no opacity ramp")
            #expect(step.animation == nil)
            #expect(step.duration == 0)
            #expect(step.isStill)
        }
    }

    // MARK: While ringing

    @Test func onePulsePerRingGrowsToOneOhSixAndBack() {
        let steps = TimerMotion.ring(.pulsePerRing, reduceMotion: false)
        #expect(steps.count == 2)
        #expect(steps.first?.from == rest)
        #expect(steps.first?.to == TimerMotion.Pose(scale: 1.06))
        #expect(steps.first?.animation == STMotion.press)
        #expect(steps.last?.from == TimerMotion.Pose(scale: 1.06))
        #expect(steps.last?.to == rest, "nothing loops: it ends where it started")
        #expect(steps.last?.animation == STMotion.quick)
        #expect(steps.allSatisfy { $0.from.offset == .zero && $0.to.offset == .zero && $0.to.opacity == 1 })
    }

    @Test func aQuickFlashDimsAndComesBackWithinItsSpacing() {
        let steps = TimerMotion.ring(.quickFlashes, reduceMotion: false)
        #expect(steps.count == 2)
        #expect(steps.first?.from == rest)
        #expect(steps.first?.to == TimerMotion.Pose(opacity: 0.25))
        #expect(steps.last?.to == rest)
        #expect(steps.allSatisfy { $0.animation == STMotion.press })
        #expect(steps.allSatisfy { $0.from.scale == 1 && $0.to.scale == 1 }, "a flash never moves the plate")
        let length = steps.map(\.duration).reduce(0, +)
        #expect(length <= AlarmSchedule.flashSpacing, "one flash fits before the next is due")
        #expect(length <= TimerMotion.minimumFlashInterval)
    }

    @Test func flashesNeverExceedThreeASecond() {
        #expect(TimerMotion.minimumFlashInterval >= 1.0 / 3)
        #expect(AlarmSchedule.flashSpacing >= TimerMotion.minimumFlashInterval)
    }

    @Test func theTimesUpLookAloneHoldsStill() {
        #expect(TimerMotion.ring(.timesUpLookOnly, reduceMotion: false).isEmpty)
    }

    /// Under Reduce animations nothing pulses or flashes, and the time's-up look holds (spec 5.6.4).
    @Test(arguments: TimerOverlaySettings.WhileRinging.allCases)
    func reducedMotionNeverPulsesOrFlashes(whileRinging: TimerOverlaySettings.WhileRinging) {
        #expect(TimerMotion.ring(whileRinging, reduceMotion: true).isEmpty)
    }

    // MARK: The nearest edge

    /// The owner's spot on a 1920 x 1080 display: center 453 right of and 459 above the middle, so 81 pt from the top.
    @Test func theOwnersSpotSlidesInFromTheTop() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let plate = CGRect(x: 1413 - 65, y: 999 - 32, width: 130, height: 64)
        #expect(TimerMotion.nearestEdge(of: plate, in: display) == .top)
    }

    @Test(arguments: [
        (CGRect(x: 900, y: 20, width: 120, height: 60), Edge.bottom),
        (CGRect(x: 10, y: 500, width: 120, height: 60), Edge.leading),
        (CGRect(x: 1790, y: 500, width: 120, height: 60), Edge.trailing),
        (CGRect(x: 900, y: 1000, width: 120, height: 60), Edge.top),
    ])
    func eachEdgeIsNearestWhereThePlateIsClosestToIt(plate: CGRect, edge: Edge) {
        #expect(TimerMotion.nearestEdge(of: plate, in: CGRect(x: 0, y: 0, width: 1920, height: 1080)) == edge)
    }

    @Test func aDisplayAwayFromTheOriginWorksTheSame() {
        let display = CGRect(x: -9000, y: -9000, width: 1512, height: 982)
        let plate = CGRect(x: -9000 + 1400, y: -9000 + 400, width: 100, height: 50)
        #expect(TimerMotion.nearestEdge(of: plate, in: display) == .trailing)
    }

    @Test func aTieGoesToTheTop() {
        let display = CGRect(x: 0, y: 0, width: 200, height: 200)
        let plate = CGRect(x: 50, y: 50, width: 100, height: 100)
        #expect(TimerMotion.nearestEdge(of: plate, in: display) == .top)
    }

    // MARK: The motion margin

    @Test(arguments: [CGSize(width: 130, height: 64), CGSize(width: 420, height: 180), CGSize(width: 900, height: 900)])
    func theMarginHoldsEveryMotion(plate: CGSize) {
        let margin = TimerMotion.margin(around: plate)
        #expect(margin == margin.rounded(), "whole points, so the plate stays on the pixel grid")
        #expect(margin >= TimerMotion.slideDistance, "a slide starts inside the panel")
        let growth = (TimerMotion.pulseScale - 1) / 2 * max(plate.width, plate.height)
        #expect(margin >= growth, "a pulse never reaches the panel's edge")
    }

    @Test func theMarginIsSmallNextToADisplay() {
        #expect(TimerMotion.margin(around: CGSize(width: 130, height: 64)) <= 32)
    }
}
