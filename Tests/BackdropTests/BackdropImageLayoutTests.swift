import CoreGraphics
import Testing
@testable import Backdrop

@Suite("Backdrop image layout")
struct BackdropImageLayoutTests {
    private let container = CGSize(width: 200, height: 100)

    @Test func stretchFillsTheContainerExactly() {
        let rect = BackdropImageLayout.rect(imageSize: CGSize(width: 50, height: 50), containerSize: container, mode: .stretch)
        #expect(rect == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func fillScalesUpToCoverAndCentersTheOverhang() {
        // A square image in a 2:1 (wide) container: fill must scale to cover the wider dimension
        // (width), so the taller-than-needed result overhangs top/bottom, never leaving a side gap.
        let rect = BackdropImageLayout.rect(imageSize: CGSize(width: 100, height: 100), containerSize: container, mode: .fill)
        #expect(rect.width == 200)
        #expect(rect.height == 200)
        #expect(rect.minX == 0)
        #expect(rect.midY == container.height / 2)
    }

    @Test func fitScalesDownToStayInsideAndCenters() {
        let rect = BackdropImageLayout.rect(imageSize: CGSize(width: 100, height: 100), containerSize: container, mode: .fit)
        #expect(rect.width == 100)
        #expect(rect.height == 100)
        #expect(rect.midX == container.width / 2)
        #expect(rect.midY == container.height / 2)
    }

    @Test func centerDrawsAtNativeSizeRegardlessOfContainer() {
        let rect = BackdropImageLayout.rect(imageSize: CGSize(width: 300, height: 20), containerSize: container, mode: .center)
        #expect(rect.width == 300)
        #expect(rect.height == 20)
        #expect(rect.midX == container.width / 2)
        #expect(rect.midY == container.height / 2)
    }

    @Test func degenerateImageSizeFallsBackToTheContainer() {
        let rect = BackdropImageLayout.rect(imageSize: .zero, containerSize: container, mode: .fit)
        #expect(rect == CGRect(origin: .zero, size: container))
    }

    @Test func degenerateContainerSizeNeverProducesNaN() {
        let rect = BackdropImageLayout.rect(imageSize: CGSize(width: 10, height: 10), containerSize: .zero, mode: .fill)
        #expect(rect == CGRect(origin: .zero, size: .zero))
    }
}
