import AppKit
import CoreGraphics
import Observation
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import TimerOverlay

// The live presenter, driven the way the controller will drive it. It's only ever handed a display far outside every
// real one, so a panel it orders in never shows on a screen. Its scheduler and clock are fakes the tests run by hand.

private let hasDisplay: Bool = {
    var count: UInt32 = 0
    return CGGetOnlineDisplayList(0, nil, &count) == .success && count > 0
}()

/// A display far outside every real one (AppKit global points).
private let offScreen = CGRect(x: -9000, y: -9000, width: 1512, height: 982)

/// A plate of the measured size for `content`, near the display's top right, like the owner's spot.
@MainActor
private func plateFrame(_ presenter: TimerOverlayPresenter, _ content: TimerOverlayContent, _ settings: TimerOverlaySettings) -> CGRect {
    let size = presenter.plateSize(for: content, settings: settings)
    return CGRect(x: offScreen.midX + 380 - size.width / 2, y: offScreen.maxY - 90 - size.height / 2,
                  width: size.width, height: size.height)
}

/// Fails the test before anything is ordered in if a real display ever reaches the off-screen one.
@MainActor
private func requireOffScreen() throws {
    try #require(!NSScreen.screens.contains { $0.frame.intersects(offScreen) }, "a display reaches \(offScreen)")
}

/// One-shot wakes that fire only when the test says so.
@MainActor
private final class ManualScheduler: TimerScheduling {
    final class Wake: TimerScheduledWake {
        let delay: TimeInterval
        var action: (@MainActor () -> Void)?

        init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }

        func cancel() { action = nil }
    }

    private(set) var wakes: [Wake] = []
    var pending: [Wake] { wakes.filter { $0.action != nil } }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TimerScheduledWake {
        let wake = Wake(delay: delay, action: action)
        wakes.append(wake)
        return wake
    }

    func fireAll() {
        for wake in pending {
            let action = wake.action
            wake.action = nil
            action?()
        }
    }
}

/// Where the test says the mouse is, in screen points.
@MainActor
private final class MouseLocation {
    var point = CGPoint(x: 500, y: 400)
}

@MainActor
private final class ManualClock: TimerClock {
    var time: TimeInterval = 1000
    func now() -> TimeInterval { time }
}

/// Counts every change of what the overlay's model draws, as SwiftUI would see it.
@MainActor
private final class ModelChanges {
    private(set) var count = 0
    private let model: TimerOverlayModel

    init(_ model: TimerOverlayModel) {
        self.model = model
        track()
    }

    private func track() {
        withObservationTracking {
            _ = model.content
            _ = model.style
            _ = model.isPlacing
            _ = model.pose
            _ = model.beat
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.count += 1
                self?.track()
            }
        }
    }
}

/// A presenter with fakes, its panels only ever on the off-screen display.
@MainActor
private struct Rig {
    let theme: STTheme
    let scheduler = ManualScheduler()
    let clock = ManualClock()
    let presenter: TimerOverlayPresenter

    init(theme: STTheme = STTheme(), mouse: @escaping @MainActor () -> CGPoint = { .zero }) {
        self.theme = theme
        presenter = TimerOverlayPresenter(theme: theme, scheduler: scheduler, clock: clock, mouseLocation: mouse)
    }

    func popIn(_ content: TimerOverlayContent = TimerOverlayContent(text: "02:30"),
               settings: TimerOverlaySettings = TimerOverlaySettings(), reduceMotion: Bool? = nil) {
        presenter.popIn(content, settings: settings, plateFrame: plateFrame(presenter, content, settings),
                        displayFrame: offScreen, reduceMotion: reduceMotion ?? theme.reduceMotion)
    }

    /// Releases whatever is up at once, so no test leaves a panel behind.
    func tearDown() {
        presenter.popOut(reduceMotion: true) {}
    }
}

/// How opaque the plate's middle is right now, 0...255.
@MainActor
private func centerAlpha(_ panel: OverlayPanel) -> Int {
    let view = panel.contentView!
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let color = rep.colorAt(x: rep.pixelsWide / 2 - rep.pixelsWide / 4, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
    return Int(((color?.alphaComponent ?? 0) * 255).rounded())
}

private func settings(_ change: (inout TimerOverlaySettings) -> Void) -> TimerOverlaySettings {
    var settings = TimerOverlaySettings()
    change(&settings)
    return settings
}

@Suite("Timer presenter lifecycle", .serialized)
@MainActor
struct TimerPresenterLifecycleTests {
    init() { _ = NSApplication.shared }

    // MARK: Idle costs nothing

    @Test func anIdlePresenterHasNoPanelAndNothingScheduled() {
        let rig = Rig()
        #expect(rig.presenter.panel == nil)
        #expect(!rig.presenter.isShowing)
        #expect(rig.presenter.plateFrame == nil)
        #expect(rig.scheduler.wakes.isEmpty)
    }

    // MARK: The panel

    @Test(.enabled(if: hasDisplay))
    func aPopInBuildsAClickThroughTopmostPanelThatCantBeHidden() throws {
        try requireOffScreen()
        let rig = Rig()
        defer { rig.tearDown() }
        rig.popIn()
        let panel = try #require(rig.presenter.panel)
        #expect(rig.presenter.isShowing)
        #expect(panel.role == .topmost)
        #expect(panel.ignoresMouseEvents, "click-through outside placement mode")
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canHide, "it stays up through Hide sTools and Hide Others")
        #expect(panel.isVisible)
        let plate = try #require(rig.presenter.plateFrame)
        #expect(panel.frame == TimerOverlayGeometry.panelFrame(plate: plate))
        #expect(offScreen.contains(plate))
    }

    @Test(.enabled(if: hasDisplay))
    func theOverlayIsInRecordingsByDefault() throws {
        try requireOffScreen()
        let rig = Rig()
        defer { rig.tearDown() }
        rig.popIn()
        let panel = try #require(rig.presenter.panel)
        #expect(!panel.isExcludedFromCapture)
        #expect(OverlayPanel.visibleWindowNumbers().contains(UInt32(panel.windowNumber)))
    }

    @Test(.enabled(if: hasDisplay))
    func showInRecordingsAppliesAtTheNextPopUp() throws {
        try requireOffScreen()
        let rig = Rig()
        defer { rig.tearDown() }
        rig.popIn()
        let hidden = settings { $0.showsInRecordings = false }
        rig.presenter.update(settings: hidden)
        #expect(rig.presenter.panel?.isExcludedFromCapture == false, "the panel up now keeps its setting")

        rig.presenter.popOut(reduceMotion: true) {}
        rig.popIn(settings: hidden)
        let panel = try #require(rig.presenter.panel)
        #expect(panel.isExcludedFromCapture)
        #expect(panel.sharingType == NSWindow.SharingType.none)
        #expect(!OverlayPanel.visibleWindowNumbers().contains(UInt32(panel.windowNumber)))
    }

    /// An overlay panel's own SwiftUI root only sees the fallback theme, which never raises contrast (spec 5.6.10), so
    /// the presenter hands the panel the theme it was given.
    @Test(.enabled(if: hasDisplay))
    func thePanelDrawsWithTheThemeItWasGiven() throws {
        try requireOffScreen()
        func render(_ theme: STTheme) throws -> Data? {
            let rig = Rig(theme: theme)
            defer { rig.tearDown() }
            rig.popIn(settings: settings { $0.look = .digitsOnly })
            let view = try #require(rig.presenter.panel?.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        let plain = try render(STTheme(motionMode: .reduced))
        let raised = try render(STTheme(motionMode: .reduced, increaseContrast: true))
        #expect(plain != nil && raised != nil)
        #expect(plain != raised, "Increase Contrast thickens the outline in the panel too")
    }

    // MARK: Cost: the content is set once per pop-up

    @Test(.enabled(if: hasDisplay))
    func theContentIsSetOncePerPopUp() throws {
        try requireOffScreen()
        let rig = Rig()
        defer { rig.tearDown() }
        rig.popIn()
        let host = try #require(rig.presenter.panel?.contentView)
        for second in stride(from: 149, through: 140, by: -1) {
            rig.presenter.update(TimerOverlayContent(text: ClockFormat.string(seconds: second)))
        }
        rig.presenter.update(settings: settings { $0.look = .compactPill })
        #expect(rig.presenter.panel?.contentView === host, "every change went through the model, never a new hosting view")

        let firstPanel = rig.presenter.panel
        rig.presenter.popOut(reduceMotion: true) {}
        rig.popIn()
        #expect(rig.presenter.panel !== firstPanel, "a new pop-up builds a new panel")
        #expect(rig.presenter.panel?.contentView !== host)
    }

    @Test(.enabled(if: hasDisplay))
    func eachSecondChangesTheModelOnceHoweverOftenItsSent() throws {
        try requireOffScreen()
        let rig = Rig()
        defer { rig.tearDown() }
        rig.popIn(TimerOverlayContent(text: "02:30"))
        let changes = ModelChanges(try #require(rig.presenter.model))
        let host = rig.presenter.panel?.contentView
        for second in stride(from: 149, through: 140, by: -1) {
            let content = TimerOverlayContent(text: ClockFormat.string(seconds: second), progress: Double(second) / 150)
            rig.presenter.update(content)
            rig.presenter.update(content)
        }
        #expect(changes.count == 10, "one change a second")
        #expect(rig.presenter.panel?.contentView === host)
    }

    @Test(.enabled(if: hasDisplay))
    func aSettingTheOverlayDoesntDrawChangesNothing() throws {
        try requireOffScreen()
        let rig = Rig()
        defer { rig.tearDown() }
        rig.popIn()
        let changes = ModelChanges(try #require(rig.presenter.model))
        rig.presenter.update(settings: settings { $0.durationSeconds = 600; $0.rings = 5; $0.whileRinging = .quickFlashes })
        #expect(changes.count == 0)
        rig.presenter.update(settings: settings { $0.digitColorHex = "#E0F0FF" })
        #expect(changes.count == 1)
    }

    // MARK: Reduced motion: nothing moves (spec 3.4)

    @Test(.enabled(if: hasDisplay))
    func reducedMotionReleasesThePanelAtOnceOnPopOut() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme(motionMode: .reduced))
        weak var released: OverlayPanel?
        var completions = 0
        autoreleasepool {
            rig.popIn()
            released = rig.presenter.panel
            #expect(released?.isVisible == true)
            rig.presenter.popOut(reduceMotion: true) { completions += 1 }
        }
        #expect(released == nil, "the panel is gone at once")
        #expect(completions == 1, "and the controller hears so at once")
        #expect(!rig.presenter.isShowing)
        #expect(rig.presenter.plateFrame == nil)
        #expect(rig.scheduler.pending.isEmpty, "nothing waits on an animation that doesn't play")
    }

    @Test(.enabled(if: hasDisplay))
    func theControllersReduceMotionAloneIsEnough() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        weak var released: OverlayPanel?
        var completions = 0
        autoreleasepool {
            rig.popIn(reduceMotion: true)
            released = rig.presenter.panel
            rig.presenter.popOut(reduceMotion: true) { completions += 1 }
        }
        #expect(released == nil)
        #expect(completions == 1)
        #expect(rig.scheduler.pending.isEmpty)
    }

    @Test(.enabled(if: hasDisplay))
    func macOSReduceMotionInTheThemeIsEnoughToo() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme(systemReduceMotion: true))
        weak var released: OverlayPanel?
        autoreleasepool {
            rig.popIn(reduceMotion: false)
            released = rig.presenter.panel
            rig.presenter.popOut(reduceMotion: false) {}
        }
        #expect(released == nil)
    }

    @Test(.enabled(if: hasDisplay), arguments: TimerOverlaySettings.PopUpMotion.allCases)
    func reducedMotionShowsThePlateAtOnceInEveryPopUpMotion(motion: TimerOverlaySettings.PopUpMotion) throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme(motionMode: .reduced))
        defer { rig.tearDown() }
        rig.popIn(settings: settings { $0.popUpMotion = motion })
        let model = try #require(rig.presenter.model)
        #expect(model.pose == .rest, "no scale, offset or fade to come")
        #expect(centerAlpha(try #require(rig.presenter.panel)) > 200, "the plate is there in its first frame")
    }

    @Test(.enabled(if: hasDisplay))
    func theControlFullMotionStartsFaded() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn()
        #expect(centerAlpha(try #require(rig.presenter.panel)) < 40, "the spring pop starts from nearly nothing")
    }

    @Test(.enabled(if: hasDisplay), arguments: TimerOverlaySettings.WhileRinging.allCases)
    func reducedMotionNeverPulsesOrFlashes(whileRinging: TimerOverlaySettings.WhileRinging) throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme(motionMode: .reduced))
        defer { rig.tearDown() }
        rig.popIn(TimerOverlayContent(text: "00:00", state: .timesUp), settings: settings { $0.whileRinging = whileRinging })
        let model = try #require(rig.presenter.model)
        let changes = ModelChanges(model)
        for _ in 0..<3 {
            rig.presenter.pulse(reduceMotion: true)
            rig.clock.time += 1.85
        }
        #expect(changes.count == 0, "the time's-up look holds")
        #expect(model.beat == .rest)
        #expect(rig.presenter.beats == 0)
        #expect(rig.scheduler.pending.isEmpty)
    }

    @Test(.enabled(if: hasDisplay))
    func theThemeIsReadAsEachMotionStarts() throws {
        try requireOffScreen()
        let theme = STTheme()
        let rig = Rig(theme: theme)
        weak var released: OverlayPanel?
        var completions = 0
        autoreleasepool {
            rig.popIn(reduceMotion: false)
            released = rig.presenter.panel
            theme.motionMode = .reduced
            rig.presenter.popOut(reduceMotion: false) { completions += 1 }
        }
        #expect(released == nil, "Reduce animations, turned on after the pop-in, applies to the pop-out")
        #expect(completions == 1)
    }

    // MARK: Full motion

    @Test(.enabled(if: hasDisplay))
    func aPopOutKeepsThePanelUntilTheExitEnds() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        var completions = 0
        rig.popIn()
        let panel = try #require(rig.presenter.panel)
        rig.presenter.popOut(reduceMotion: false) { completions += 1 }
        #expect(rig.presenter.isShowing, "the exit plays")
        #expect(panel.isVisible)
        #expect(completions == 0)
        #expect(rig.scheduler.pending.count == 1, "one wake, in case the animation never reports its end")
        let wake = try #require(rig.scheduler.pending.first)
        #expect(wake.delay > 0.25 && wake.delay < 1)

        rig.scheduler.fireAll()
        #expect(!rig.presenter.isShowing)
        #expect(!panel.isVisible)
        #expect(completions == 1)
        #expect(rig.scheduler.pending.isEmpty)
    }

    @Test(.enabled(if: hasDisplay))
    func theExitEndsOnceWhicheverEndComesFirst() async throws {
        try requireOffScreen()
        // The live scheduler: the animation's own end or the backstop wake, whichever is first, releases the panel.
        let presenter = TimerOverlayPresenter(theme: STTheme())
        let content = TimerOverlayContent(text: "02:30")
        presenter.popIn(content, settings: TimerOverlaySettings(), plateFrame: plateFrame(presenter, content, TimerOverlaySettings()),
                        displayFrame: offScreen, reduceMotion: false)
        var completions = 0
        presenter.popOut(reduceMotion: false) { completions += 1 }
        let deadline = SuspendingClock.now.advanced(by: .seconds(20))
        while presenter.isShowing, SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!presenter.isShowing)
        try await Task.sleep(for: .milliseconds(800))
        #expect(completions == 1, "never twice")
    }

    @Test(.enabled(if: hasDisplay))
    func aPopInWhileLeavingReplacesTheOldPanelAtOnce() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        weak var old: OverlayPanel?
        var oldCompletions = 0
        autoreleasepool {
            rig.popIn()
            old = rig.presenter.panel
            rig.presenter.popOut(reduceMotion: false) { oldCompletions += 1 }
            rig.popIn(TimerOverlayContent(text: "02:30"))
        }
        #expect(old == nil, "the leaving panel is released at once")
        #expect(oldCompletions == 0, "it didn't leave: a new countdown came")
        #expect(rig.presenter.isShowing)
        #expect(rig.scheduler.pending.isEmpty, "its backstop wake is cancelled")
    }

    @Test func aPopOutWithNothingUpCompletesAtOnce() {
        let rig = Rig()
        var completions = 0
        rig.presenter.popOut(reduceMotion: false) { completions += 1 }
        #expect(completions == 1)
        #expect(rig.scheduler.wakes.isEmpty)
    }

    @Test(.enabled(if: hasDisplay))
    func aSecondPopOutWhileLeavingEndsWithTheFirst() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        var first = 0
        var second = 0
        rig.popIn()
        rig.presenter.popOut(reduceMotion: false) { first += 1 }
        rig.presenter.popOut(reduceMotion: false) { second += 1 }
        #expect(rig.scheduler.pending.count == 1)
        rig.scheduler.fireAll()
        #expect(first == 1 && second == 1)
        #expect(!rig.presenter.isShowing)
    }

    @Test(.enabled(if: hasDisplay))
    func aPulseGrowsThePlate() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn(TimerOverlayContent(text: "00:00", state: .timesUp))
        let model = try #require(rig.presenter.model)
        let changes = ModelChanges(model)
        rig.presenter.pulse(reduceMotion: false)
        #expect(rig.presenter.beats == 1)
        #expect(changes.count == 1)
        #expect(model.beat == TimerMotion.Pose(scale: TimerMotion.pulseScale), "on its way to 1.06, and back after")
        #expect(model.pose == .rest, "the pop-in's pose is left alone")
    }

    @Test(.enabled(if: hasDisplay))
    func theTimesUpLookAloneHoldsStill() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn(TimerOverlayContent(text: "00:00", state: .timesUp), settings: settings { $0.whileRinging = .timesUpLookOnly })
        let changes = ModelChanges(try #require(rig.presenter.model))
        rig.presenter.pulse(reduceMotion: false)
        #expect(changes.count == 0)
        #expect(rig.presenter.beats == 0)
    }

    @Test(.enabled(if: hasDisplay))
    func flashesComeAtMostThreeASecond() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn(TimerOverlayContent(text: "00:00", state: .timesUp), settings: settings { $0.whileRinging = .quickFlashes })
        let model = try #require(rig.presenter.model)
        rig.presenter.pulse(reduceMotion: false)
        #expect(model.beat == TimerMotion.Pose(opacity: TimerMotion.flashOpacity))
        #expect(rig.presenter.beats == 1)
        rig.clock.time += 0.2
        rig.presenter.pulse(reduceMotion: false)
        #expect(rig.presenter.beats == 1, "a flash 0.2 s after the last is skipped")
        rig.clock.time += 0.2
        rig.presenter.pulse(reduceMotion: false)
        #expect(rig.presenter.beats == 2, "0.4 s after it, the next one plays")
        rig.clock.time += 0.34
        rig.presenter.pulse(reduceMotion: false)
        #expect(rig.presenter.beats == 3, "a third of a second apart is the most there can be")
    }

    @Test(.enabled(if: hasDisplay))
    func nothingPulsesOnTheWayOut() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        rig.popIn(TimerOverlayContent(text: "00:00", state: .timesUp))
        rig.presenter.popOut(reduceMotion: false) {}
        let changes = ModelChanges(try #require(rig.presenter.model))
        rig.presenter.pulse(reduceMotion: false)
        #expect(changes.count == 0)
        #expect(rig.presenter.beats == 0)
        rig.scheduler.fireAll()
    }

    // MARK: Moving and resizing

    @Test(.enabled(if: hasDisplay))
    func aMoveMovesThePanelAtOnce() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn()
        let plate = try #require(rig.presenter.plateFrame)
        let moved = plate.offsetBy(dx: -120, dy: -300)
        rig.presenter.move(plateFrame: moved, displayFrame: offScreen)
        #expect(rig.presenter.plateFrame == moved)
        #expect(rig.presenter.panel?.frame == TimerOverlayGeometry.panelFrame(plate: moved), "no animated frame")
    }

    @Test(.enabled(if: hasDisplay))
    func moreDigitsGrowThePlateAroundItsCenter() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn(TimerOverlayContent(text: "00:10", state: .nearZeroDanger))
        let before = try #require(rig.presenter.plateFrame)
        rig.presenter.update(TimerOverlayContent(text: "00:09.9", state: .nearZeroDanger))
        let after = try #require(rig.presenter.plateFrame)
        #expect(after.width > before.width)
        #expect(abs(after.midX - before.midX) <= 0.5 && abs(after.midY - before.midY) <= 0.5)
        #expect(rig.presenter.panel?.frame == TimerOverlayGeometry.panelFrame(plate: after))
        let size = rig.presenter.plateSize(for: TimerOverlayContent(text: "00:09.8", state: .nearZeroDanger), settings: TimerOverlaySettings())
        #expect(after.size == size)
    }

    @Test(.enabled(if: hasDisplay))
    func aTickMeasuresNothing() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn()
        let measured = rig.presenter.measureCount
        let plate = rig.presenter.plateFrame
        for second in stride(from: 149, through: 100, by: -1) {
            rig.presenter.update(TimerOverlayContent(text: ClockFormat.string(seconds: second)))
        }
        #expect(rig.presenter.measureCount == measured, "the same digits in tabular figures can't change the size")
        #expect(rig.presenter.plateFrame == plate)
    }

    @Test(.enabled(if: hasDisplay))
    func pausingAddsALineAroundTheSameCenter() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.popIn(TimerOverlayContent(text: "01:02"))
        let counting = try #require(rig.presenter.plateFrame)
        rig.presenter.update(TimerOverlayContent(text: "01:02", state: .paused))
        let paused = try #require(rig.presenter.plateFrame)
        #expect(paused.height > counting.height)
        #expect(abs(paused.midY - counting.midY) <= 0.5)
    }

    // MARK: Placement mode

    @Test(.enabled(if: hasDisplay))
    func placementModeTakesTheMouseAndReportsDragsOnScreen() throws {
        try requireOffScreen()
        let mouse = MouseLocation()
        let rig = Rig(theme: STTheme(), mouse: { mouse.point })
        defer { rig.tearDown() }
        rig.popIn()
        var translations: [CGSize] = []
        var ends = 0
        rig.presenter.setPlacementMode(true, onDragChanged: { translations.append($0) }, onDragEnded: { ends += 1 })
        let panel = try #require(rig.presenter.panel)
        let model = try #require(rig.presenter.model)
        #expect(panel.isMouseHandlingEnabled)
        #expect(model.isPlacing)
        #expect(!panel.canBecomeKey, "placing never takes focus")

        model.onDragChanged()
        mouse.point = CGPoint(x: 530, y: 380)
        model.onDragChanged()
        mouse.point = CGPoint(x: 470, y: 450)
        model.onDragChanged()
        model.onDragEnded()
        #expect(translations == [.zero, CGSize(width: 30, height: 20), CGSize(width: -30, height: -50)],
                "measured on the screen from where the drag started, +y down, however the panel moves")
        #expect(ends == 1)
    }

    @Test(.enabled(if: hasDisplay))
    func placementModeLastsAcrossPopUpsUntilTurnedOff() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        defer { rig.tearDown() }
        rig.presenter.setPlacementMode(true, onDragChanged: { _ in }, onDragEnded: {})
        rig.popIn()
        #expect(rig.presenter.panel?.isMouseHandlingEnabled == true)
        #expect(rig.presenter.model?.isPlacing == true)

        rig.presenter.setPlacementMode(false, onDragChanged: { _ in }, onDragEnded: {})
        #expect(rig.presenter.panel?.isMouseHandlingEnabled == false, "click-through again")
        #expect(rig.presenter.model?.isPlacing == false)
        rig.presenter.popOut(reduceMotion: true) {}
        rig.popIn()
        #expect(rig.presenter.panel?.isMouseHandlingEnabled == false)
    }

    // MARK: After the exit

    @Test(.enabled(if: hasDisplay))
    func afterTheExitNothingIsLeft() throws {
        try requireOffScreen()
        let rig = Rig(theme: STTheme())
        rig.popIn()
        let number = try #require(rig.presenter.panel?.windowNumber)
        rig.presenter.popOut(reduceMotion: false) {}
        rig.scheduler.fireAll()
        #expect(rig.presenter.panel == nil)
        #expect(rig.presenter.model == nil)
        #expect(rig.scheduler.pending.isEmpty)
        #expect(!NSApp.windows.contains { $0.windowNumber == number && $0.isVisible })
        #expect(!OverlayPanel.visibleWindowNumbers().contains(UInt32(number)))
    }
}
