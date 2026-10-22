import Foundation
import STDesign
import SwiftUI
import Testing
@testable import sTools

/// Records what would play, and when, instead of playing anything.
@MainActor
final class FakeSidebarSound: SidebarSoundPlaying {
    var isAudible = true
    private(set) var played: [(sound: STSound, at: TimeInterval)] = []
    private let clock: FakeGlideClock

    init(clock: FakeGlideClock) { self.clock = clock }

    func play(_ sound: STSound) { played.append((sound, clock.now)) }

    var sounds: [STSound] { played.map(\.sound) }
    var glides: [STSound] { sounds.filter { $0 != .detent } }
    var detentTimes: [TimeInterval] { played.filter { $0.sound == .detent }.map(\.at) }
}

/// A clock the test moves by hand; its timers fire in order as it passes them.
@MainActor
final class FakeGlideClock: SidebarGlideClock {
    final class FakeTimer: SidebarGlideTimer {
        let due: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false
        var hasFired = false
        init(due: TimeInterval, action: @escaping @MainActor () -> Void) { self.due = due; self.action = action }
        func cancel() { isCancelled = true }
    }

    var now: TimeInterval = 1_000
    private(set) var timers: [FakeTimer] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SidebarGlideTimer {
        let timer = FakeTimer(due: now + delay, action: action)
        timers.append(timer)
        return timer
    }

    /// Timers neither fired nor cancelled.
    var waiting: [FakeTimer] { timers.filter { !$0.isCancelled && !$0.hasFired } }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = waiting.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            now = next.due
            next.hasFired = true
            next.action()
        }
        now = end
    }
}

/// A glide player on a fake sound player and clock, counting haptic taps.
@MainActor
private struct Rig {
    let clock = FakeGlideClock()
    let sound: FakeSidebarSound
    let player: SidebarGlidePlayer
    let taps: TapCounter

    final class TapCounter { var count = 0 }

    init(reduceMotion: Bool = false, layout: SidebarLayout = SidebarLayout()) {
        sound = FakeSidebarSound(clock: clock)
        let taps = TapCounter()
        self.taps = taps
        player = SidebarGlidePlayer(sound: sound, clock: clock, haptic: { taps.count += 1 },
                                    reduceMotion: { reduceMotion })
        player.layout = layout
    }
}

/// Home, five tools and Settings, measured in a window of the default size: the sidebar of ducky's example.
private let fiveToolRows: [CGFloat] = [0, 66.5, 122.5, 178.5, 234.5, 290.5, 387]

private func position(after time: TimeInterval, from start: CGFloat, to end: CGFloat) -> CGFloat {
    start + SidebarGlide.spring.value(target: end - start, time: time)
}

@MainActor
@Suite("Sidebar glide and detents")
struct SidebarGlideTests {
    /// The detents are timed by the spring the marker animates with, which is the app's `standard` motion.
    @Test func theMarkerAnimatesWithTheStandardSpring() {
        #expect(SidebarGlide.markerAnimation == STMotion.standard)
    }

    @Test func homeToSettingsPassesFiveToolsWithFiveDetentsAndOneGlide() {
        let plan = SidebarGlide.plan(from: .init(position: fiveToolRows[0]), to: fiveToolRows[6],
                                     passing: Array(fiveToolRows.dropLast()))
        #expect(plan.glide == .glideLong)
        #expect(plan.detents.count == 5)
    }

    /// Each detent lands as the marker's center crosses a row's center, on the spring's own curve.
    @Test func eachDetentLandsAsTheMarkerCrossesARowCenter() {
        let plan = SidebarGlide.plan(from: .init(position: 0), to: 387, passing: Array(fiveToolRows.dropLast()))
        #expect(plan.detents == plan.detents.sorted())
        for (time, row) in zip(plan.detents, fiveToolRows[1...5]) {
            #expect(abs(position(after: time, from: 0, to: 387) - row) < 0.25, "row \(row) at \(time)")
        }
        // Fast in the middle of the move, slower toward its end: the gaps shrink, then grow.
        let gaps = zip(plan.detents, plan.detents.dropFirst()).map { $1 - $0 }
        #expect(gaps.last! > gaps.min()!)
        #expect(plan.detents.first! > 0 && plan.detents.last! < 0.4)
    }

    /// Moving up the sidebar is timed the same way, crossing the rows bottom to top.
    @Test func movingUpTimesTheDetentsTheSameWay() {
        let up = SidebarGlide.plan(from: .init(position: 387), to: 0, passing: Array(fiveToolRows.dropFirst()))
        #expect(up.glide == .glideLong)
        #expect(up.detents.count == 5)
        for (time, row) in zip(up.detents, fiveToolRows[1...5].reversed()) {
            #expect(abs(position(after: time, from: 387, to: 0) - row) < 0.25, "row \(row) at \(time)")
        }
    }

    /// Every pair of rows: one detent per row strictly between them, none for a neighbor, and the glide for the
    /// distance traveled.
    @Test func everyRoutePairPlaysOneDetentPerRowBetween() {
        let order = SidebarGlide.order
        let layout = SidebarLayout()
        for (fromIndex, from) in order.enumerated() {
            for (toIndex, to) in order.enumerated() where from != to {
                let rig = Rig()
                rig.player.glide(from: from, to: to)
                rig.clock.advance(by: 2)
                let expected = abs(toIndex - fromIndex) - 1
                #expect(rig.sound.detentTimes.count == expected, "\(from) → \(to)")
                #expect(rig.taps.count == expected, "\(from) → \(to)")
                let travel = layout.center(of: to) - layout.center(of: from)
                #expect(rig.sound.glides == [SidebarGlide.glide(forTravel: travel)], "\(from) → \(to)")
                #expect(rig.sound.played.first?.sound != .detent, "the glide starts first")
                #expect(rig.clock.waiting.isEmpty)
            }
        }
    }

    @Test func homeToSettingsThroughThePlayerCrossesEveryTool() {
        let rig = Rig()
        rig.player.glide(from: .home, to: .settings)
        #expect(rig.sound.glides == [.glideLong])
        #expect(rig.clock.waiting.count == ToolID.allCases.count)
        rig.clock.advance(by: 1)
        #expect(rig.sound.detentTimes.count == ToolID.allCases.count)
        #expect(rig.taps.count == ToolID.allCases.count)
        #expect(rig.sound.detentTimes == rig.sound.detentTimes.sorted())
        #expect(rig.player.pendingCount == 0, "nothing is held once the glide is over")
    }

    @Test func aNeighborPlaysTheShortGlideAndNoDetent() {
        let rig = Rig()
        rig.player.glide(from: .tool(.windowBackdrop), to: .tool(.crosshair))
        rig.clock.advance(by: 1)
        #expect(rig.sound.sounds == [.glideShort])
        #expect(rig.taps.count == 0)
        #expect(rig.clock.timers.isEmpty, "nothing scheduled")
    }

    @Test(arguments: [
        (CGFloat(56), STSound.glideShort), (66.5, .glideShort), (96.5, .glideShort), (-99, .glideShort),
        (112, .glideMedium), (168, .glideMedium), (-122.5, .glideMedium),
        (224, .glideLong), (387, .glideLong), (-300, .glideLong),
    ])
    func theGlideFollowsTheDistance(_ travel: CGFloat, _ glide: STSound) {
        #expect(SidebarGlide.glide(forTravel: travel) == glide)
    }

    /// Measured centers win over the estimate: rows far apart make even a neighbor's glide long.
    @Test func theMeasuredLayoutDecidesTheGlide() {
        var layout = SidebarLayout()
        layout.centers[.tool(.keyRebinder)] = 300
        layout.centers[.settings] = 520
        let rig = Rig(layout: layout)
        rig.player.glide(from: .tool(.keyRebinder), to: .settings)
        #expect(rig.sound.glides == [.glideLong])
    }

    /// A new move mid-glide cancels the old detents and starts from where the marker is, still moving.
    @Test func aNewMoveMidGlideReplacesTheOldOne() throws {
        let rig = Rig()
        let layout = SidebarLayout()
        rig.player.glide(from: .home, to: .settings)
        rig.clock.advance(by: 0.08)
        let firedBefore = rig.sound.detentTimes.count
        #expect(firedBefore > 0 && firedBefore < ToolID.allCases.count)
        let oldTimers = rig.clock.waiting

        rig.player.glide(from: .settings, to: .tool(.nbbOverlay))
        #expect(oldTimers.allSatisfy { $0.isCancelled }, "the old glide's detents are cancelled")
        #expect(rig.sound.glides.count == 2)

        // The new move is planned from the marker's real position and speed 80 ms into the first one.
        let midFlight = try #require(SidebarGlide.motion(from: .init(position: layout.center(of: .home)),
                                                         to: layout.center(of: .settings), after: 0.08))
        #expect(midFlight.velocity > 0)
        let rows = SidebarGlide.order.filter { $0 != .tool(.nbbOverlay) }.map(layout.center(of:))
        let expected = SidebarGlide.plan(from: midFlight, to: layout.center(of: .tool(.nbbOverlay)), passing: rows)
        let interruptedAt = rig.clock.now
        rig.clock.advance(by: 2)
        let newDetents = rig.sound.detentTimes.dropFirst(firedBefore).map { $0 - interruptedAt }
        #expect(newDetents.count == expected.detents.count)
        for (heard, planned) in zip(newDetents, expected.detents) { #expect(abs(heard - planned) < 1e-9) }
        #expect(rig.clock.waiting.isEmpty)
    }

    /// Once a glide has settled, the next starts from the row the marker rests on.
    @Test func aMoveAfterTheGlideSettledStartsFromRest() {
        let rig = Rig()
        rig.player.glide(from: .home, to: .tool(.crosshair))
        rig.clock.advance(by: 2)
        rig.player.glide(from: .tool(.crosshair), to: .home)
        rig.clock.advance(by: 2)
        #expect(rig.sound.detentTimes.count == 4, "two rows each way")
    }

    @Test func reducedMotionPlaysOnlyABriefGlide() {
        let rig = Rig(reduceMotion: true)
        rig.player.glide(from: .home, to: .settings)
        rig.clock.advance(by: 2)
        #expect(rig.sound.sounds == [.glideShort])
        #expect(rig.clock.timers.isEmpty)
        #expect(rig.taps.count == 0)
    }

    @Test func soundsOffPlaysAndSchedulesNothing() {
        let rig = Rig()
        rig.sound.isAudible = false
        rig.player.glide(from: .home, to: .settings)
        rig.clock.advance(by: 2)
        #expect(rig.sound.played.isEmpty)
        #expect(rig.clock.timers.isEmpty)
        #expect(rig.taps.count == 0)
    }

    @Test func stayingOnTheSameRowPlaysNothing() {
        let rig = Rig()
        rig.player.glide(from: .settings, to: .settings)
        #expect(rig.sound.played.isEmpty)
        #expect(rig.clock.timers.isEmpty)
    }

    /// The app's own player is quiet in tests: sounds off means `isAudible` is false and nothing is scheduled.
    @Test func theRealPlayerSchedulesNothingWhileSoundsAreOff() {
        let theme = STTheme(soundsEnabled: false)
        let clock = FakeGlideClock()
        let player = SidebarGlidePlayer(sound: STSoundPlayer(theme: theme, systemSoundsEnabled: { true }),
                                        clock: clock, haptic: {}, reduceMotion: { false })
        player.glide(from: .home, to: .settings)
        #expect(clock.timers.isEmpty)
    }
}

/// Clicking a row, the Go menu and Back/Forward all glide; none plays the old page sound.
@MainActor
@Suite("Sidebar glide from navigation")
struct SidebarGlideNavigationTests {
    private func rigged() -> (Harness, FakeGlideClock, FakeSidebarSound) {
        let harness = Harness()
        let clock = FakeGlideClock()
        let sound = FakeSidebarSound(clock: clock)
        harness.model.sidebarGlide = SidebarGlidePlayer(sound: sound, clock: clock, haptic: {},
                                                        reduceMotion: { harness.model.theme.reduceMotion })
        return (harness, clock, sound)
    }

    @Test func navigatingGlidesWithADetentPerRowPassed() {
        let (harness, clock, sound) = rigged()
        harness.model.navigate(to: .settings)
        clock.advance(by: 1)
        #expect(sound.glides == [.glideLong])
        #expect(sound.detentTimes.count == ToolID.allCases.count)
        #expect(!sound.sounds.contains(.page))
    }

    @Test func theGoMenuGlidesTheSameWay() {
        let (harness, clock, sound) = rigged()
        harness.model.perform(.tool(.crosshair))
        clock.advance(by: 1)
        #expect(sound.glides == [.glideMedium])
        #expect(sound.detentTimes.count == 2)
        harness.model.perform(.tool(.crosshair))
        #expect(sound.glides.count == 1, "the page already open plays nothing")
    }

    @Test func backAndForwardGlide() {
        let (harness, clock, sound) = rigged()
        harness.model.navigate(to: .tool(.windowBackdrop))
        clock.advance(by: 1)
        harness.model.perform(.back)
        clock.advance(by: 1)
        harness.model.perform(.forward)
        clock.advance(by: 1)
        #expect(sound.glides == [.glideMedium, .glideMedium, .glideMedium])
        #expect(sound.detentTimes.count == 3, "NBB Overlay each way")
        #expect(!sound.sounds.contains(.page))
    }

    @Test func reduceAnimationsLeavesOnlyTheBriefGlide() {
        let (harness, clock, sound) = rigged()
        harness.model.updateAppearance { $0.motionMode = .reduced }
        harness.model.navigate(to: .settings)
        clock.advance(by: 1)
        #expect(sound.sounds == [.glideShort])
        #expect(clock.timers.isEmpty)
    }
}

/// The sidebar tells the glide where its rows are as it lays out, so the detents follow the real layout.
@MainActor
@Suite("Sidebar row centers")
struct SidebarRowCenterTests {
    @Test func theSidebarReportsEveryRowsCenterTopToBottom() {
        let harness = Harness()
        _ = renderBitmap(SidebarView(model: harness.model).environment(\.stTheme, harness.model.theme),
                         size: CGSize(width: 236, height: 560))
        let centers = harness.model.sidebarGlide.layout.centers
        let ordered = SidebarGlide.order.compactMap { centers[$0] }
        #expect(ordered.count == SidebarGlide.order.count, "every row reported")
        #expect(ordered == ordered.sorted() && Set(ordered).count == ordered.count, "top to bottom")
    }
}
