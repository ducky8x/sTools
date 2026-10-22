import AppKit
import CoreGraphics
import STDesign
import SwiftUI
import Testing
@testable import TimerOverlay

private let fullHD = CGRect(x: 0, y: 0, width: 1920, height: 1080)

/// The owner's spot on a 1920 x 1080 display (spec 5.6.5): the plate's center 453 right of and 459 above the middle.
private func ownersSpot(_ size: CGSize) -> CGRect {
    CGRect(x: 960 + 453 - size.width / 2, y: 540 + 459 - size.height / 2, width: size.width, height: size.height)
}

@Suite("Timer presenter geometry")
@MainActor
struct TimerPresenterGeometryTests {
    // MARK: The panel around the plate

    @Test func thePanelIsThePlateWithItsMotionMarginAllAround() {
        let plate = CGRect(x: 1348, y: 967, width: 130, height: 64)
        let margin = TimerMotion.margin(around: plate.size)
        let panel = TimerOverlayGeometry.panelFrame(plate: plate)
        #expect(panel == plate.insetBy(dx: -margin, dy: -margin))
        #expect(panel.midX == plate.midX && panel.midY == plate.midY, "the plate sits in the middle, where SwiftUI centers it")
        #expect(panel == panel.integral, "whole points")
    }

    @Test func thePanelCoversThePlateNotTheDisplay() {
        let panel = TimerOverlayGeometry.panelFrame(plate: ownersSpot(CGSize(width: 130, height: 64)))
        #expect(panel.width * panel.height < fullHD.width * fullHD.height / 50)
    }

    @Test func everyMotionStaysInsideThePanel() {
        let plate = CGRect(x: 100, y: 100, width: 420, height: 180)
        let panel = TimerOverlayGeometry.panelFrame(plate: plate)
        let pulsed = plate.insetBy(dx: -plate.width * (TimerMotion.pulseScale - 1) / 2, dy: -plate.height * (TimerMotion.pulseScale - 1) / 2)
        #expect(panel.contains(pulsed))
        for offset in [CGSize(width: 0, height: -24), CGSize(width: 0, height: 24), CGSize(width: -24, height: 0), CGSize(width: 24, height: 0)] {
            #expect(panel.contains(plate.offsetBy(dx: offset.width, dy: offset.height)))
        }
    }

    @Test(arguments: [CGPoint(x: 10.5, y: 20.4), CGPoint(x: -9000.25, y: -8999.5), CGPoint(x: 1347.7, y: 967.2)])
    func aPlateOnPartPointsLandsOnWholePoints(origin: CGPoint) {
        let plate = TimerOverlayGeometry.wholePoints(CGRect(origin: origin, size: CGSize(width: 130, height: 64)))
        #expect(plate.origin.x == plate.origin.x.rounded() && plate.origin.y == plate.origin.y.rounded())
        #expect(plate.size == CGSize(width: 130, height: 64))
        #expect(abs(plate.minX - origin.x) <= 0.5 && abs(plate.minY - origin.y) <= 0.5)
    }

    // MARK: A plate that changes size while it's up

    @Test func aGrowingPlateKeepsItsCenter() {
        let plate = CGRect(x: 800, y: 500, width: 130, height: 64)
        let grown = TimerOverlayGeometry.resized(plate, to: CGSize(width: 170, height: 84), within: fullHD)
        #expect(grown.size == CGSize(width: 170, height: 84))
        #expect(grown.midX == plate.midX && grown.midY == plate.midY)
    }

    @Test func aShrinkingPlateKeepsItsCenterOnWholePoints() {
        let plate = CGRect(x: 800, y: 500, width: 130, height: 64)
        let shrunk = TimerOverlayGeometry.resized(plate, to: CGSize(width: 105, height: 64), within: fullHD)
        #expect(shrunk.size == CGSize(width: 105, height: 64))
        #expect(abs(shrunk.midX - plate.midX) <= 0.5)
        #expect(shrunk.minX == shrunk.minX.rounded())
    }

    @Test func aGrowingPlateStaysOnTheDisplay() {
        // Against the top right corner: growing around its center would cross both edges.
        let plate = CGRect(x: 1920 - 130, y: 1080 - 64, width: 130, height: 64)
        let grown = TimerOverlayGeometry.resized(plate, to: CGSize(width: 190, height: 100), within: fullHD)
        #expect(fullHD.contains(grown))
        #expect(grown.maxX == fullHD.maxX && grown.maxY == fullHD.maxY)
    }

    @Test func aPlateAlreadyPastTheEdgeKeepsItsCenter() {
        // Mid-drag the controller may hold the plate partly off the display; a tick never yanks it back.
        let plate = CGRect(x: 1880, y: 500, width: 130, height: 64)
        let grown = TimerOverlayGeometry.resized(plate, to: CGSize(width: 150, height: 64), within: fullHD)
        #expect(grown.midX == plate.midX)
    }

    @Test func aPlateWiderThanTheDisplayStartsAtItsLeftEdge() {
        let small = CGRect(x: 0, y: 0, width: 300, height: 200)
        let grown = TimerOverlayGeometry.resized(CGRect(x: 100, y: 50, width: 100, height: 60), to: CGSize(width: 400, height: 60), within: small)
        #expect(grown.minX == small.minX)
    }

    // MARK: Measuring the plate (no window)

    @Test func theMeasuredSizeIsTheViewsOwn() {
        let presenter = TimerOverlayPresenter(theme: STTheme())
        for look in TimerOverlaySettings.Look.allCases {
            var settings = TimerOverlaySettings()
            settings.look = look
            let content = TimerOverlayContent(text: "02:30")
            let own = NSHostingController(rootView: TimerOverlayView(content: content, settings: settings).environment(\.stTheme, STTheme()))
                .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            #expect(presenter.plateSize(for: content, settings: settings) == own, "\(look)")
        }
        #expect(presenter.panel == nil, "measuring builds no panel")
    }

    @Test func theDefaultPlateIsCloseToTheOldOverlay() {
        // At 40 pt the merged timer app's overlay covered 153 x 63 px; the owner's spot is its center (spec 5.6.5).
        let size = TimerOverlayPresenter(theme: STTheme()).plateSize(for: TimerOverlayContent(text: "02:30"), settings: TimerOverlaySettings())
        #expect(abs(size.width - 153) <= 30 && abs(size.height - 63) <= 10, "\(size)")
    }

    @Test func increaseContrastFromTheThemeIsMeasured() {
        var settings = TimerOverlaySettings()
        settings.look = .digitsOnly
        let content = TimerOverlayContent(text: "02:30")
        let normal = TimerOverlayPresenter(theme: STTheme()).plateSize(for: content, settings: settings)
        let raised = TimerOverlayPresenter(theme: STTheme(increaseContrast: true)).plateSize(for: content, settings: settings)
        #expect(raised.width > normal.width, "the thicker outline gets its room")
    }

    @Test func theSameShapeIsMeasuredOnce() {
        let presenter = TimerOverlayPresenter(theme: STTheme())
        let settings = TimerOverlaySettings()
        _ = presenter.plateSize(for: TimerOverlayContent(text: "02:30"), settings: settings)
        _ = presenter.plateSize(for: TimerOverlayContent(text: "02:29"), settings: settings)
        _ = presenter.plateSize(for: TimerOverlayContent(text: "01:59", state: .nearZeroGold), settings: settings)
        #expect(presenter.measureCount == 1, "same digits count, same caption: the size can't change")
        _ = presenter.plateSize(for: TimerOverlayContent(text: "00:09.9"), settings: settings)
        #expect(presenter.measureCount == 2)
        _ = presenter.plateSize(for: TimerOverlayContent(text: "00:09", state: .paused), settings: settings)
        #expect(presenter.measureCount == 3, "the Paused mark adds a line")
    }

    // MARK: Where a slide comes from

    @Test func theOwnersSpotSlidesDownFromTheTop() {
        let edge = TimerMotion.nearestEdge(of: ownersSpot(CGSize(width: 130, height: 64)), in: fullHD)
        #expect(edge == .top)
        #expect(TimerMotion.popIn(.slide, from: edge, reduceMotion: false).from.offset.height < 0, "SwiftUI's up is negative")
    }
}
