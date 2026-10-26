import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Crosshair
@testable import STPlatform

/// The default crosshair is 3 px thick, so it has one center pixel with the same number of pixels on every
/// side of it (revision 30). A Plus is `2 × size + thickness` pixels across, so its thickness alone decides
/// whether it has a center pixel; the default's 11 px arms make it 25 px across, 12 on each side.
@MainActor
@Suite("Crosshair default symmetry", .serialized)
struct CrosshairDefaultSymmetryTests {
    private let defaults = CrosshairSettings.defaultValue

    @Test func theDefaultIsThreePixelsThickWithOneCenterPixel() {
        #expect(defaults.shape == .plus)
        #expect(defaults.thickness == 3)
        #expect(defaults.size == 11)
        let length = CrosshairShapeMath.centeringLength(shape: defaults.shape, size: defaults.size, thickness: defaults.thickness)
        #expect(length == 3)
        #expect(CrosshairShapeMath.centerFraction(shape: defaults.shape, size: defaults.size, thickness: defaults.thickness) == 0.5)
        // 11 + 3 + 11: an odd extent, so there's a single middle pixel across and down.
        #expect(2 * defaults.size + defaults.thickness == 25)
    }

    // The sprite itself, before it's placed: 25 white pixels each way, the hot pixel in the middle of them.
    @Test func theDefaultSpriteMirrorsAroundItsHotPixel() {
        let sprite = CrosshairRenderer.builtIn(settings: defaults)
        let pixels = RGBABitmap(sprite.image)
        let center = sprite.hot
        let counts = sideCounts(in: pixels, center: center)
        #expect(counts.white == SideCounts(left: 12, right: 12, up: 12, down: 12))
        #expect(counts.drawn == SideCounts(left: 14, right: 14, up: 14, down: 14))
        #expect(mirrorMismatches(in: pixels, center: center).isEmpty)
    }

    // The real overlay at the default, on even and odd displays at 1x and 2x: the center pixel is the display's
    // center pixel (the middle one, or the one just left of and above the middle of an even count) moved by the
    // default offset, and the crosshair has the same pixels on every side of it, outline included.
    @Test(arguments: [DisplayCase.fullHD, .fullHDAt2x, .oddAt1x, .oddAt2x, .builtInAt2x])
    func theDefaultOverlayIsSymmetricAroundOneCenterPixel(display: DisplayCase) throws {
        let overlay = renderOverlay(defaults, displays: [display.info])
        let panel = try #require(panelOrigin(overlay.frame, on: display))
        let center = PixelPoint(
            x: display.center.x + defaults.offsetX - panel.x, y: display.center.y + defaults.offsetY - panel.y)
        #expect(overlay.bitmap[center.x, center.y] == .white)
        let counts = sideCounts(in: overlay.bitmap, center: center)
        #expect(counts.white == SideCounts(left: 12, right: 12, up: 12, down: 12))
        #expect(counts.drawn == SideCounts(left: 14, right: 14, up: 14, down: 14))
        let mismatches = mirrorMismatches(in: overlay.bitmap, center: center)
        #expect(mismatches.isEmpty, "\(mismatches.count) pixels differ from their mirror image, first \(mismatches.prefix(3))")
        // The center line is 3 px: the center column and one on each side of it.
        let lineColumns = (0..<overlay.bitmap.width).filter { overlay.bitmap[$0, center.y - 5] == .white }
        #expect(lineColumns == [center.x - 1, center.x, center.x + 1])
    }

    // On 1920 x 1080 the middle falls between columns 959 and 960: the center pixel is 959 (just left of it, as
    // for every crosshair) and the default's −1 offset moves it to 958, so the 3 px line covers 957–959, the
    // columns of Minecraft's own crosshair at GUI scale 3. The same holds on a 2x display that looks like it.
    @Test(arguments: [
        (DisplayCase.fullHD, PixelPoint(x: 958, y: 538)),
        (DisplayCase.fullHDAt2x, PixelPoint(x: 1918, y: 1078)),
        (DisplayCase.oddAt1x, PixelPoint(x: 681, y: 382)),
    ])
    func theDefaultsCenterPixelIsTheDisplaysCenterPixelMovedByTheOffset(display: DisplayCase, expected: PixelPoint) throws {
        let overlay = renderOverlay(defaults, displays: [display.info])
        let panel = try #require(panelOrigin(overlay.frame, on: display))
        var white = [PixelPoint]()
        for y in 0..<overlay.bitmap.height {
            for x in 0..<overlay.bitmap.width where overlay.bitmap[x, y] == .white {
                white.append(PixelPoint(x: panel.x + x, y: panel.y + y))
            }
        }
        let columns = white.map(\.x), rows = white.map(\.y)
        let middle = PixelPoint(x: (columns.min()! + columns.max()!) / 2, y: (rows.min()! + rows.max()!) / 2)
        #expect(middle == expected)
        #expect(columns.max()! - middle.x == middle.x - columns.min()!)
        #expect(rows.max()! - middle.y == middle.y - rows.min()!)
    }

    // Without the offset, on a display with a middle pixel, the default sits exactly on it: as many display
    // pixels left of the crosshair as right of it.
    @Test func withoutTheOffsetTheDefaultSitsOnAnOddDisplaysMiddlePixel() throws {
        var centered = defaults
        centered.offsetX = 0
        centered.offsetY = 0
        let display = DisplayCase.oddAt1x
        let overlay = renderOverlay(centered, displays: [display.info])
        let panel = try #require(panelOrigin(overlay.frame, on: display))
        let bounds = try #require(overlay.bitmap.drawnBounds)
        let width = Int(display.frame.width), height = Int(display.frame.height)
        #expect(panel.x + bounds.minX == width - 1 - (panel.x + bounds.maxX))
        #expect(panel.y + bounds.minY == height - 1 - (panel.y + bounds.maxY))
        #expect(CrosshairCentering.note(for: centered, on: PixelSize(width: width, height: height)) == nil)
    }

    @Test func resetGivesTheThreePixelDefaultAndSavesIt() async {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = makeServices(tempDirectory: directory)
        let controller = makeController(services)
        controller.settings.size = 10
        controller.settings.thickness = 2
        controller.settings.offsetX = 0
        controller.resetToDefault()
        #expect(controller.settings == defaults)
        await services.settings.flush()
        let reloaded = makeController(makeServices(tempDirectory: directory))
        #expect(reloaded.settings == defaults)
        #expect(reloaded.settings.thickness == 3)
    }

    // A saved crosshair is the person's own: values saved on disk load as they are, an earlier build's
    // defaults (10 px arms, 2 px thick, no offset) included; only what's missing takes today's default.
    @Test func savedSettingsLoadAsTheyAre() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = #"{"version": 1, "value": {"shape": "plus", "size": 10, "thickness": 2, "offsetX": 0, "offsetY": 0}}"#
        try Data(old.utf8).write(to: directory.appending(path: "crosshair.json"))
        let loaded = makeController(makeServices(tempDirectory: directory)).settings
        #expect(loaded.size == 10 && loaded.thickness == 2 && loaded.offsetX == 0 && loaded.offsetY == 0)

        let partial = ##"{"version": 1, "value": {"shape": "plus", "fillHex": "#FF0000"}}"##
        try Data(partial.utf8).write(to: directory.appending(path: "crosshair.json"))
        let filled = makeController(makeServices(tempDirectory: directory)).settings
        #expect(filled.fillHex == "#FF0000")
        #expect(filled.size == 11 && filled.thickness == 3 && filled.offsetX == -1 && filled.offsetY == -1)
    }

    // MARK: - Helpers

    struct SideCounts: Equatable {
        var left: Int
        var right: Int
        var up: Int
        var down: Int
    }

    /// How many pixels run unbroken from the center pixel in each direction: white ones, and drawn ones
    /// (anything not fully transparent, the outline included).
    private func sideCounts(in bitmap: RGBABitmap, center: PixelPoint) -> (white: SideCounts, drawn: SideCounts) {
        func run(_ dx: Int, _ dy: Int, _ isIn: (RGBA) -> Bool) -> Int {
            var count = 0
            while isIn(bitmap[center.x + (count + 1) * dx, center.y + (count + 1) * dy]) { count += 1 }
            return count
        }
        func counts(_ isIn: (RGBA) -> Bool) -> SideCounts {
            SideCounts(left: run(-1, 0, isIn), right: run(1, 0, isIn), up: run(0, -1, isIn), down: run(0, 1, isIn))
        }
        return (counts { $0 == .white }, counts { $0.alpha > 0 })
    }

    /// The pixels that differ from their mirror image across the center pixel's column or row.
    private func mirrorMismatches(in bitmap: RGBABitmap, center: PixelPoint) -> [PixelPoint] {
        var wrong = [PixelPoint]()
        for y in -1...bitmap.height {
            for x in -1...bitmap.width {
                let pixel = bitmap[x, y]
                if pixel != bitmap[2 * center.x - x, y] || pixel != bitmap[x, 2 * center.y - y] {
                    wrong.append(PixelPoint(x: x, y: y))
                }
            }
        }
        return wrong
    }

    /// The panel's top-left pixel on its display's pixel grid. Nil when it isn't on that grid.
    private func panelOrigin(_ frame: CGRect, on display: DisplayCase) -> PixelPoint? {
        let left = (frame.minX - display.frame.minX) * display.scale
        let top = (display.frame.maxY - frame.maxY) * display.scale
        guard left == left.rounded(), top == top.rounded() else { return nil }
        return PixelPoint(x: Int(left), y: Int(top))
    }
}
