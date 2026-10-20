import CoreGraphics
import Testing
@testable import NBBOverlay

@Suite("NBB placement snapping")
struct NBBPlacementSnappingTests {
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func snapsToTheLeftEdgeWhenClose() {
        let frame = CGRect(x: 10, y: 400, width: 300, height: 200)
        let snapped = NBBPlacementSnapping.snapped(frame, in: display, threshold: 14)
        #expect(snapped.origin.x == 0)
        #expect(snapped.origin.y == 400, "the Y axis is untouched since it wasn't near any snap point")
    }

    @Test func snapsToTheRightEdgeWhenClose() {
        let rightAligned = display.maxX - 300
        let frame = CGRect(x: rightAligned - 5, y: 400, width: 300, height: 200)
        let snapped = NBBPlacementSnapping.snapped(frame, in: display, threshold: 14)
        #expect(snapped.origin.x == rightAligned)
    }

    @Test func snapsToHorizontalCenterWhenClose() {
        let targetX = display.midX - 150 // frame width 300, perfectly centered
        let frame = CGRect(x: targetX + 8, y: 400, width: 300, height: 200)
        let snapped = NBBPlacementSnapping.snapped(frame, in: display, threshold: 14)
        #expect(snapped.origin.x == targetX)
    }

    @Test func snapsToTopAndBottomEdges() {
        let top = CGRect(x: 100, y: 5, width: 300, height: 200)
        #expect(NBBPlacementSnapping.snapped(top, in: display, threshold: 14).origin.y == 0)

        let bottomY = display.maxY - 200
        let bottom = CGRect(x: 100, y: bottomY - 6, width: 300, height: 200)
        #expect(NBBPlacementSnapping.snapped(bottom, in: display, threshold: 14).origin.y == bottomY)
    }

    @Test func doesNotSnapWhenFarFromEveryCandidate() {
        let frame = CGRect(x: 500, y: 500, width: 300, height: 200)
        let snapped = NBBPlacementSnapping.snapped(frame, in: display, threshold: 14)
        #expect(snapped == frame)
    }

    @Test func picksTheClosestCandidateWhenTwoAreWithinThreshold() {
        // A tiny display where left-edge and center both sit within threshold of the frame's x.
        let smallDisplay = CGRect(x: 0, y: 0, width: 320, height: 200)
        let frame = CGRect(x: 4, y: 0, width: 300, height: 200) // left edge at distance 4, center (10) at distance 6
        let snapped = NBBPlacementSnapping.snapped(frame, in: smallDisplay, threshold: 14)
        #expect(snapped.origin.x == 0, "left edge (closer) wins over center")
    }

    @Test func sizeIsNeverChangedByASnap() {
        let frame = CGRect(x: 2, y: 2, width: 300, height: 200)
        let snapped = NBBPlacementSnapping.snapped(frame, in: display, threshold: 14)
        #expect(snapped.size == frame.size)
    }
}
