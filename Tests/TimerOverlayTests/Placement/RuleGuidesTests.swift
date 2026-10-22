import AppKit
import CoreGraphics
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import TimerOverlay

// The rule guides (spec 5.6.5): what they draw, how they come and go (spec 3.4), and how long their window lives
// (the plan's cost rule). Views are rendered in a window that's never ordered in; the live presenter is only ever
// handed a display at (-8000, -8000), far outside every real one, so nothing reaches a screen.

private let hasDisplay: Bool = {
    var count: UInt32 = 0
    return CGGetOnlineDisplayList(0, nil, &count) == .success && count > 0
}()

/// A 14-inch MacBook Pro's display, far outside every real one.
private let offScreen = DisplayInfo(
    id: 999, name: "Off screen", frame: CGRect(x: -8000, y: -8000, width: 1512, height: 982),
    bounds: CGRect(x: -8000, y: 8000, width: 1512, height: 982), backingScale: 2,
    pixelSize: CGSize(width: 3024, height: 1964), isMain: false)

/// A small display for rendering, at GUI scale 2.
private let small = DisplayInfo(
    id: 1, name: "Small", frame: CGRect(x: 0, y: 0, width: 960, height: 540),
    bounds: CGRect(x: 0, y: 0, width: 960, height: 540), backingScale: 1,
    pixelSize: CGSize(width: 960, height: 540), isMain: true)

private func zones(on display: DisplayInfo, scale: TimerOverlaySettings.GUIScale = .fixed(3)) -> RuleZones {
    var settings = TimerOverlaySettings()
    settings.guiScale = scale
    return RuleZones(settings: settings, display: display, minecraft: nil)
}

/// A plate over the toast column (top right) of `display`, below SpeedRunIGT's lines: 167-230 pt from the top.
private func plateOverToasts(on display: DisplayInfo) -> CGRect {
    CGRect(x: display.frame.maxX - 200, y: display.frame.maxY - 230, width: 153, height: 63)
}

// MARK: - Rendering

/// Never shown: hosts a view so it can be drawn to a bitmap.
@MainActor
private final class Still {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init<V: View>(_ view: V, size: CGSize) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    isolated deinit {
        window.contentView = nil
    }

    /// After letting every pending update and animation through.
    func settled() -> NSBitmapImageRep {
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return now()
    }

    /// Right away, without running the run loop, so an animation can't get far.
    func now() -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        return render(host)
    }
}

@MainActor
private func render(_ view: NSView) -> NSBitmapImageRep {
    let size = view.bounds.size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

private func sameImage(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let left = a.bitmapData, let right = b.bitmapData else { return false }
    return memcmp(left, right, a.bytesPerRow * a.pixelsHigh) == 0
}

/// The alpha of the strongest pixel: 0 when nothing is drawn.
private func strongestAlpha(_ rep: NSBitmapImageRep) -> Int {
    guard let data = rep.bitmapData else { return 0 }
    var strongest = 0
    for row in 0..<rep.pixelsHigh {
        for column in 0..<rep.pixelsWide {
            strongest = max(strongest, Int(data[row * rep.bytesPerRow + column * 4 + 3]))
        }
    }
    return strongest
}

@MainActor
private func guides(_ model: RuleGuidesModel, theme: STTheme) -> Still {
    Still(RuleGuidesView(model: model, startsShown: theme.reduceMotion).stMotionRoot(theme).environment(\.stTheme, theme),
          size: model.display.size)
}

// MARK: - The view

@Suite("Rule guides: the view", .serialized)
@MainActor
struct RuleGuidesViewTests {
    @Test func withMotionReducedTheyAreThereAtOnce() {
        let theme = STTheme(motionMode: .reduced)
        let still = guides(RuleGuidesModel(zones: zones(on: small, scale: .fixed(2)), display: small.frame), theme: theme)
        let first = still.now()
        #expect(strongestAlpha(first) > 200, "the outlines are drawn in full from the first frame")
        #expect(sameImage(first, still.settled()), "nothing fades in")
    }

    @Test func macOSReduceMotionDoesTheSame() {
        let theme = STTheme(systemReduceMotion: true)
        let still = guides(RuleGuidesModel(zones: zones(on: small, scale: .fixed(2)), display: small.frame), theme: theme)
        let first = still.now()
        #expect(sameImage(first, still.settled()))
    }

    /// The control: with full motion the guides fade in, so the first frame isn't the last.
    @Test func withFullMotionTheyFadeIn() {
        let theme = STTheme()
        let still = guides(RuleGuidesModel(zones: zones(on: small, scale: .fixed(2)), display: small.frame), theme: theme)
        let first = still.now()
        let last = still.settled()
        #expect(strongestAlpha(last) > 200)
        #expect(!sameImage(first, last), "caught on its way in")
    }

    @Test(arguments: [STMotionMode.full, .reduced])
    func coveringAZoneShowsAtOnceInBothModes(mode: STMotionMode) {
        let theme = STTheme(motionMode: mode)
        let model = RuleGuidesModel(zones: zones(on: small, scale: .fixed(2)), display: small.frame)
        let still = guides(model, theme: theme)
        let before = still.settled()

        model.mark([.toasts], plateFrame: plateOverToasts(on: small))
        let first = still.now()
        let last = still.settled()
        #expect(!sameImage(before, last), "the toasts turned danger and the line appeared")
        #expect(sameImage(first, last), "no animation")

        model.mark([], plateFrame: CGRect(x: 400, y: 200, width: 153, height: 63))
        let cleared = still.now()
        #expect(sameImage(cleared, before), "back to plain outlines at once")
    }

    @Test func eachZoneIsOutlinedOnce() {
        let zones = zones(on: small, scale: .fixed(2))
        let model = RuleGuidesModel(zones: zones, display: small.frame)
        #expect(model.outlines.count == zones.zones.reduce(0) { $0 + $1.rects.count })
        let toasts = zones.zones.first { $0.kind == .toasts }!.rects[0]
        #expect(model.outlines.contains { $0.kind == .toasts && $0.rect == CGRect(x: toasts.minX, y: 0, width: toasts.width, height: toasts.height) },
                "the panel's coordinates start at the display's top-left corner")
    }
}

// MARK: - The line under the plate

@Suite("Rule guides: the line")
@MainActor
struct RuleGuidesLineTests {
    private let bounds = CGSize(width: 1920, height: 1080)
    private let line = CGSize(width: 300, height: 30)

    @Test func itSitsCenteredUnderThePlate() {
        let plate = CGRect(x: 800, y: 300, width: 153, height: 63)
        let origin = BesidePlate.origin(of: line, beside: plate, in: bounds)
        #expect(origin.y == plate.maxY + BesidePlate.gap)
        #expect(abs(origin.x + line.width / 2 - plate.midX) <= 0.5)
    }

    @Test func itGoesAboveWhenThereIsNoRoomBelow() {
        let plate = CGRect(x: 800, y: 1000, width: 153, height: 63)
        let origin = BesidePlate.origin(of: line, beside: plate, in: bounds)
        #expect(origin.y + line.height == plate.minY - BesidePlate.gap)
    }

    @Test func itStaysOnTheDisplayBesideAPlateInTheCorner() {
        // The owner's spot over the toasts is near the right edge: the line can't be centered there.
        let right = BesidePlate.origin(of: line, beside: CGRect(x: 1800, y: 50, width: 120, height: 63), in: bounds)
        #expect(right.x + line.width == bounds.width - BesidePlate.gap)
        let left = BesidePlate.origin(of: line, beside: CGRect(x: 0, y: 50, width: 120, height: 63), in: bounds)
        #expect(left.x == BesidePlate.gap)
    }

    @Test func itNamesTheCoveredZones() {
        let model = RuleGuidesModel(zones: zones(on: small, scale: .fixed(2)), display: small.frame)
        model.mark([.toasts, .speedRunIGT], plateFrame: plateOverToasts(on: small))
        #expect(model.line == "Covers the toasts and SpeedRunIGT\u{2019}s timer")
    }
}

// MARK: - The live presenter

@Suite("Rule guides: the live presenter", .serialized)
@MainActor
struct RuleGuidesPresenterTests {
    init() { _ = NSApplication.shared }

    @Test func thereIsNoWindowBeforeADrag() {
        let presenter = RuleGuidesPresenter(theme: STTheme())
        #expect(presenter.panel == nil)
        presenter.markCovered([.toasts], plateFrame: plateOverToasts(on: offScreen))
        #expect(presenter.panel == nil, "marking without a drag builds nothing")
        presenter.hide()
    }

    @Test(.enabled(if: hasDisplay))
    func withMotionReducedTheGuidesComeAndGoAtOnce() throws {
        let presenter = RuleGuidesPresenter(theme: STTheme(motionMode: .reduced))
        weak var weakPanel: OverlayPanel?
        try autoreleasepool {
            presenter.show(zones(on: offScreen), on: offScreen)
            let panel = try #require(presenter.panel)
            weakPanel = panel
            #expect(panel.isVisible)
            #expect(panel.frame == offScreen.frame, "the whole display")
            #expect(panel.ignoresMouseEvents, "click-through: the drag goes to the plate")
            #expect(panel.isExcludedFromCapture, "never in a recording")
            #expect(!panel.canBecomeKey)

            let host = try #require(panel.contentView)
            host.layoutSubtreeIfNeeded()
            let first = render(host)
            #expect(strongestAlpha(first) > 200, "there at once")
            for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            host.layoutSubtreeIfNeeded()
            #expect(sameImage(first, render(host)), "nothing faded in")

            presenter.markCovered([.toasts], plateFrame: plateOverToasts(on: offScreen))
            #expect(presenter.model?.covered == [.toasts])
            host.layoutSubtreeIfNeeded()
            let marked = render(host)
            for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            host.layoutSubtreeIfNeeded()
            #expect(!sameImage(first, marked) && sameImage(marked, render(host)), "danger at once")

            presenter.hide()
        }
        #expect(presenter.panel == nil)
        #expect(weakPanel == nil, "the window is gone as the drag ends")
    }

    @Test(.enabled(if: hasDisplay))
    func withFullMotionTheWindowStillGoesAsTheDragEnds() {
        let presenter = RuleGuidesPresenter(theme: STTheme())
        weak var weakPanel: OverlayPanel?
        autoreleasepool {
            presenter.show(zones(on: offScreen), on: offScreen)
            weakPanel = presenter.panel
            #expect(weakPanel?.isVisible == true)
            presenter.hide()
        }
        #expect(weakPanel == nil)
    }

    @Test(.enabled(if: hasDisplay))
    func aNewDragReplacesTheGuides() {
        let presenter = RuleGuidesPresenter(theme: STTheme(motionMode: .reduced))
        weak var first: OverlayPanel?
        autoreleasepool {
            presenter.show(zones(on: offScreen), on: offScreen)
            first = presenter.panel
            presenter.show(zones(on: offScreen, scale: .fixed(2)), on: offScreen)
        }
        #expect(first == nil)
        #expect(presenter.panel?.isVisible == true)
        #expect(presenter.buildCount == 2)
        presenter.hide()
    }

    @Test func theGuidesSitUnderThePlateAndAboveTheGame() {
        let overlay = OverlayPanel(role: .topmost).level.rawValue
        let guides = RuleGuidesPresenter.level.rawValue
        #expect(guides < overlay)
        #expect(guides > Int(CGWindowLevelForKey(.mainMenuWindow)))
        #expect(guides > Int(CGWindowLevelForKey(.dockWindow)))
        // Minecraft's own full screen sits just above the menu bar.
        #expect(guides > Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
    }

    /// The cost rule: the zones are worked out once per drag; a move only runs the overlap test, and redraws
    /// nothing unless what's covered, or the plate under a line, changed.
    @Test(.enabled(if: hasDisplay))
    func movesRedrawOnlyWhatChanged() throws {
        let presenter = RuleGuidesPresenter(theme: STTheme(motionMode: .reduced))
        let zones = zones(on: offScreen)
        presenter.show(zones, on: offScreen)
        defer { presenter.hide() }
        let model = try #require(presenter.model)

        var plate = CGRect(x: offScreen.frame.midX, y: offScreen.frame.midY, width: 153, height: 63)
        for _ in 0..<100 {
            plate = plate.offsetBy(dx: 1, dy: 0)
            presenter.markCovered(zones.covered(by: plate), plateFrame: plate)
        }
        #expect(model.changeCount == 0, "moving over open ground changes nothing")

        let overToasts = plateOverToasts(on: offScreen)
        presenter.markCovered(zones.covered(by: overToasts), plateFrame: overToasts)
        #expect(model.covered == [.toasts])
        let afterCovering = model.changeCount
        presenter.markCovered(zones.covered(by: overToasts), plateFrame: overToasts)
        #expect(model.changeCount == afterCovering, "the same spot again changes nothing")

        presenter.markCovered(zones.covered(by: overToasts.offsetBy(dx: -5, dy: 0)), plateFrame: overToasts.offsetBy(dx: -5, dy: 0))
        #expect(model.changeCount == afterCovering + 1, "only the line follows the plate")
        #expect(presenter.buildCount == 1, "the view is built once per drag")
    }
}
