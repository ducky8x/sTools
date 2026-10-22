import CoreGraphics
import STPlatform
import Testing
@testable import TimerOverlay

/// A display for the placement math. Nothing here orders a window in, so the frames can be anywhere.
private func display(
    id: UInt32 = 1, x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1920, height: CGFloat = 1080,
    scale: CGFloat = 1, isMain: Bool = true
) -> DisplayInfo {
    DisplayInfo(
        id: id, name: "Display \(id)", frame: CGRect(x: x, y: y, width: width, height: height),
        bounds: CGRect(x: x, y: -y, width: width, height: height), backingScale: scale,
        pixelSize: CGSize(width: width * scale, height: height * scale), isMain: isMain)
}

/// The owner's 1920 x 1080 display at 1x, and the 4K display at 2x that looks like it.
private let hd = display()
private let hdRetina = display(scale: 2)

/// The plate the merged timer app drew at 40 pt: x 1336-1489, 50-113 px from the top (spec 5.6.5).
private let ownersPlate = CGSize(width: 153, height: 63)
private let ownersOffset = TimerPlacement.Offset(x: 453, y: -459)

/// The frame's top edge measured down from the display's top, as the spec gives positions.
private func top(_ frame: CGRect, on display: DisplayInfo) -> CGFloat { display.frame.maxY - frame.maxY }

@Suite("Timer placement")
struct TimerPlacementTests {
    // MARK: The owner's spot

    @Test func theDefaultIsTheOwnersSavedSpotExactly() {
        #expect(TimerPlacement.Offset(TimerOverlaySettings()) == ownersOffset)
        let frame = TimerPlacement.plateFrame(size: ownersPlate, offset: ownersOffset, on: hd)
        #expect(frame.minX == 1336 && frame.maxX == 1489)
        #expect(top(frame, on: hd) == 50 && top(frame, on: hd) + frame.height == 113)
    }

    @Test func onA2xDisplayThatLooksLike1080pItIsTheSameSpotInPoints() {
        let frame = TimerPlacement.plateFrame(size: ownersPlate, offset: ownersOffset, on: hdRetina)
        // Half points are whole pixels at 2x, so the plate is centered exactly.
        #expect(frame == CGRect(x: 1336.5, y: 967.5, width: 153, height: 63))
        #expect(frame.midX == 960 + 453 && frame.midY == 540 + 459)
    }

    @Test func aBiggerPlateGrowsAroundTheSameCenter() {
        let small = TimerPlacement.plateFrame(size: ownersPlate, offset: ownersOffset, on: hdRetina)
        let big = TimerPlacement.plateFrame(size: CGSize(width: 301, height: 141), offset: ownersOffset, on: hdRetina)
        #expect(big.midX == small.midX && big.midY == small.midY)
        #expect(big.width == 301 && big.height == 141)
    }

    @Test(arguments: [CGFloat(1), 2])
    func theFrameSitsOnTheDisplaysPixelGrid(scale: CGFloat) {
        let display = display(scale: scale)
        for size in [CGSize(width: 153, height: 63), CGSize(width: 152.3, height: 61.7), CGSize(width: 90.25, height: 40.5)] {
            let frame = TimerPlacement.plateFrame(size: size, offset: ownersOffset, on: display)
            for value in [frame.minX, frame.minY, frame.width, frame.height] {
                #expect((value * scale).rounded() == value * scale, "\(value) at \(scale)x")
            }
            #expect(frame.width >= size.width && frame.width - size.width < 1 / scale)
            #expect(frame.height >= size.height && frame.height - size.height < 1 / scale)
        }
    }

    @Test func aDisplayAwayFromTheOriginPlacesAroundItsOwnCenter() {
        let left = display(id: 2, x: -1512, y: 120, width: 1512, height: 982, scale: 2, isMain: false)
        let frame = TimerPlacement.plateFrame(size: CGSize(width: 100, height: 40), offset: .init(x: -200, y: 100), on: left)
        #expect(frame.midX == left.frame.midX - 200)
        #expect(frame.midY == left.frame.midY - 100, "+y is down")
    }

    // MARK: Clamping (decision 2)

    @Test func theDefaultSpotIsKeptOnADisplayTooShortForIt() {
        let laptop = display(width: 1440, height: 900, scale: 2)
        let frame = TimerPlacement.plateFrame(size: ownersPlate, offset: ownersOffset, on: laptop)
        #expect(frame.maxY == laptop.frame.maxY, "459 pt above the middle is past the top, so the plate rests on it")
        #expect(frame.midX == laptop.frame.midX + 453, "the other axis keeps its spot")
        #expect(laptop.frame.contains(frame))
        // Nothing is stored: the same offset still gives the exact spot on the owner's display.
        let back = TimerPlacement.plateFrame(size: ownersPlate, offset: ownersOffset, on: hd)
        #expect(back.minX == 1336 && top(back, on: hd) == 50)
    }

    @Test func everyOffsetEndsUpInsideTheDisplay() {
        for (x, y) in [(-5000, 0), (5000, 0), (0, -5000), (0, 5000), (16_384, -16_384), (-16_384, 16_384)] {
            let frame = TimerPlacement.plateFrame(size: ownersPlate, offset: .init(x: x, y: y), on: hdRetina)
            #expect(hdRetina.frame.contains(frame), "(\(x), \(y))")
        }
    }

    @Test func aPlateBiggerThanTheDisplayKeepsItsTopLeftCorner() {
        let tiny = display(width: 320, height: 240)
        let frame = TimerPlacement.plateFrame(size: CGSize(width: 400, height: 300), offset: .init(x: 0, y: 0), on: tiny)
        #expect(frame.minX == tiny.frame.minX)
        #expect(frame.maxY == tiny.frame.maxY)
    }

    // MARK: Back to an offset

    @Test(arguments: [CGFloat(1), 2])
    func anOffsetSurvivesTheRoundTrip(scale: CGFloat) {
        let display = display(scale: scale)
        let sizes = [CGSize(width: 153, height: 63), CGSize(width: 154, height: 64), CGSize(width: 152.3, height: 61.7)]
        for size in sizes {
            for x in stride(from: -700, through: 700, by: 77) {
                for y in stride(from: -400, through: 400, by: 61) {
                    let offset = TimerPlacement.Offset(x: x, y: y)
                    let frame = TimerPlacement.plateFrame(size: size, offset: offset, on: display)
                    #expect(TimerPlacement.offset(of: frame, on: display) == offset, "\(offset) \(size) at \(scale)x")
                }
            }
        }
    }

    @Test func theOffsetIsMeasuredFromTheDisplaysCenterWithYDown() {
        let frame = CGRect(x: 960 - 50 + 100, y: 540 - 20 - 30, width: 100, height: 40)
        #expect(TimerPlacement.offset(of: frame, on: hd) == .init(x: 100, y: 30))
    }

    // MARK: Settling a drag

    @Test func aDragThatEndsNearTheRightEdgeSnapsFlushAndStaysThere() {
        let size = CGSize(width: 152.5, height: 63)
        let dragged = CGRect(x: 1920 - 152.5 - 9, y: 600, width: 152.5, height: 63)
        let settled = TimerPlacement.settle(dragged, on: hdRetina, snapping: true)
        #expect(settled.frame.maxX == hdRetina.frame.maxX)
        #expect(TimerPlacement.plateFrame(size: size, offset: settled.offset, on: hdRetina) == settled.frame,
                "the stored offset gives back the settled spot")
    }

    @Test(arguments: [CGFloat(1), 2])
    func everyEdgeSnapIsFlushAfterTheRoundTrip(scale: CGFloat) {
        let display = display(scale: scale)
        let size = CGSize(width: 152.5, height: 62.5)
        let near: [CGRect] = [
            CGRect(x: 6, y: 500, width: size.width, height: size.height),                          // left
            CGRect(x: 1920 - size.width - 6, y: 500, width: size.width, height: size.height),      // right
            CGRect(x: 700, y: 1080 - size.height - 6, width: size.width, height: size.height),     // top
            CGRect(x: 700, y: 7, width: size.width, height: size.height),                          // bottom
        ]
        let settled = near.map { TimerPlacement.settle($0, on: display, snapping: true) }
        #expect(settled[0].frame.minX == 0)
        #expect(settled[1].frame.maxX == 1920)
        #expect(settled[2].frame.maxY == 1080)
        #expect(settled[3].frame.minY == 0)
        for result in settled {
            #expect(TimerPlacement.plateFrame(size: size, offset: result.offset, on: display) == result.frame)
        }
    }

    @Test func snappingOffLeavesTheDropWhereItIs() {
        let dragged = CGRect(x: 1920 - 153 - 9, y: 600, width: 153, height: 63)
        let settled = TimerPlacement.settle(dragged, on: hd, snapping: false)
        #expect(settled.frame == dragged)
    }

    @Test func aDragPastTheEdgeSettlesInsideAndStoresTheInsideSpot() {
        let dragged = CGRect(x: 1850, y: 1060, width: 153, height: 63)
        let settled = TimerPlacement.settle(dragged, on: hd, snapping: false)
        #expect(hd.frame.contains(settled.frame))
        #expect(settled.frame.maxX == 1920 && settled.frame.maxY == 1080)
        #expect(TimerPlacement.plateFrame(size: dragged.size, offset: settled.offset, on: hd) == settled.frame)
    }

    @Test func snapsToTheCenterWhenClose() {
        let dragged = CGRect(x: 960 - 76 + 10, y: 300, width: 152, height: 63)
        let settled = TimerPlacement.settle(dragged, on: hd, snapping: true)
        #expect(settled.offset.x == 0)
        #expect(settled.frame.midX == 960)
    }

    // MARK: Which display

    @Test func followingMinecraftUsesItsDisplay() {
        let main = display(id: 1)
        let side = display(id: 2, x: 1920, isMain: false)
        let chosen = TimerPlacement.display(choice: .followMinecraft, specificDisplayID: 1, minecraftDisplayID: 2, in: [main, side])
        #expect(chosen?.id == 2)
    }

    @Test func withoutMinecraftItIsTheMainDisplay() {
        let side = display(id: 2, x: 1920, isMain: false)
        let main = display(id: 1)
        #expect(TimerPlacement.display(choice: .followMinecraft, specificDisplayID: nil, minecraftDisplayID: nil, in: [side, main])?.id == 1)
        #expect(TimerPlacement.display(choice: .followMinecraft, specificDisplayID: nil, minecraftDisplayID: 9, in: [side, main])?.id == 1,
                "a display that's gone counts as none")
    }

    @Test func aSpecificDisplayWinsUntilItIsGone() {
        let main = display(id: 1)
        let side = display(id: 2, x: 1920, isMain: false)
        #expect(TimerPlacement.display(choice: .specific, specificDisplayID: 2, minecraftDisplayID: 1, in: [main, side])?.id == 2)
        #expect(TimerPlacement.display(choice: .specific, specificDisplayID: 3, minecraftDisplayID: 2, in: [main, side])?.id == 1)
        #expect(TimerPlacement.display(choice: .specific, specificDisplayID: nil, minecraftDisplayID: 2, in: [main, side])?.id == 1)
    }

    @Test func withNoMainDisplayTheFirstOneIsUsedAndWithNoneThereIsNone() {
        let side = display(id: 2, x: 1920, isMain: false)
        #expect(TimerPlacement.display(choice: .followMinecraft, specificDisplayID: nil, minecraftDisplayID: nil, in: [side])?.id == 2)
        #expect(TimerPlacement.display(choice: .followMinecraft, specificDisplayID: nil, minecraftDisplayID: nil, in: []) == nil)
    }

    @Test func theSettingsChooseTheDisplay() {
        var settings = TimerOverlaySettings()
        settings.displayChoice = .specific
        settings.specificDisplayID = 2
        let main = display(id: 1)
        let side = display(id: 2, x: 1920, isMain: false)
        #expect(TimerPlacement.display(for: settings, minecraftDisplayID: 1, in: [main, side])?.id == 2)
    }
}
