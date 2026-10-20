import CoreGraphics
import Testing

@testable import Crosshair

@Suite("Crosshair centering")
struct CrosshairCenteringTests {
    private let fullHD = PixelSize(width: 1920, height: 1080)

    private func settings(_ shape: CrosshairSettings.Shape, size: Int = 10, thickness: Int) -> CrosshairSettings {
        var settings = CrosshairSettings.defaultValue
        settings.shape = shape
        settings.size = size
        settings.thickness = thickness
        return settings
    }

    @Test func theDefaultCrosshairIsExactlyCenteredOnCommonDisplays() {
        let defaults = CrosshairSettings.defaultValue
        for display in [fullHD, PixelSize(width: 2560, height: 1440), PixelSize(width: 3024, height: 1964), PixelSize(width: 3840, height: 2160)] {
            #expect(CrosshairCentering.note(for: defaults, on: display) == nil)
        }
    }

    @Test(arguments: [(2, true), (3, false), (4, true), (1, false)])
    func evenThicknessesCenterOnAnEvenDisplay(thickness: Int, centers: Bool) {
        #expect(CrosshairGeometry.centersExactly(length: thickness, on: fullHD) == centers)
        #expect((CrosshairCentering.note(for: settings(.plus, thickness: thickness), on: fullHD) == nil) == centers)
    }

    @Test func oddThicknessesCenterOnAnOddDisplay() {
        let odd = PixelSize(width: 1365, height: 767)
        #expect(CrosshairCentering.note(for: settings(.plus, thickness: 3), on: odd) == nil)
        #expect(CrosshairCentering.note(for: settings(.plus, thickness: 2), on: odd) != nil)
    }

    @Test func theNoteNamesTheWidthsThatWouldCenter() throws {
        let note = try #require(CrosshairCentering.note(for: settings(.plus, thickness: 3), on: fullHD))
        #expect(note.contains("1920 \u{00D7} 1080"))
        #expect(note.contains("2 px or 4 px"))
        let thin = try #require(CrosshairCentering.note(for: settings(.x, thickness: 1), on: fullHD))
        #expect(thin.contains("2 px") && !thin.contains("0 px"))
    }

    @Test func dotsAndCirclesGoByTheirSize() {
        #expect(CrosshairCentering.note(for: settings(.dot, size: 9, thickness: 2), on: fullHD) != nil)
        #expect(CrosshairCentering.note(for: settings(.circle, size: 10, thickness: 3), on: fullHD) == nil)
    }

    @Test func imagesAreLeftToTheirAnchor() {
        #expect(CrosshairCentering.note(for: settings(.image, thickness: 3), on: fullHD) == nil)
    }

    @Test func aDisplayEvenOneWayAndOddTheOtherSaysSo() throws {
        let note = try #require(CrosshairCentering.note(for: settings(.plus, thickness: 2), on: PixelSize(width: 2731, height: 1400)))
        #expect(note.contains("both ways"))
    }

    // End to end on 1920 x 1080: a 2 px plus with its outline covers as many pixels on each side of the
    // display's middle (between pixels 959 and 960, and 539 and 540).
    @Test func anEvenCrosshairIsSymmetricAboutTheDisplaysMiddle() {
        let fill = CrosshairShapeMath.mask(shape: .plus, size: 10, thickness: 2, gap: 0, margin: 2)
        let outlined = CrosshairOutline.dilated(fill, width: 2)
        let placement = CrosshairGeometry.placement(
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1,
            spriteSize: PixelSize(width: outlined.width, height: outlined.height), hotPixel: outlined.hot, offsetX: 0, offsetY: 0)
        let left = placement.targetPixel.x - outlined.hot.x
        let top = placement.targetPixel.y - outlined.hot.y
        for mask in [fill, outlined] {
            var columns = [Int]()
            var rows = [Int]()
            for y in 0..<mask.height {
                for x in 0..<mask.width where mask.coverage(x: x, y: y) > 0 {
                    columns.append(left + x)
                    rows.append(top + y)
                }
            }
            #expect(columns.min()! + columns.max()! == 959 + 960)
            #expect(rows.min()! + rows.max()! == 539 + 540)
        }
    }
}
