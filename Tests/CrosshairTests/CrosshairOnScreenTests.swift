import AppKit
import CoreGraphics
import Testing
@testable import Crosshair
@testable import STPlatform

/// A display to place the crosshair on, with its center pixel worked out by hand: the middle pixel of an odd
/// count, the one just left of (or above) the middle of an even one.
struct DisplayCase: Sendable, CustomTestStringConvertible {
    let frame: CGRect
    let scale: CGFloat
    let center: PixelPoint

    var testDescription: String { "\(frame.width) x \(frame.height) pt at (\(frame.minX), \(frame.minY)), \(Int(scale))x" }

    var info: DisplayInfo { syntheticDisplay(frame: frame, scale: scale) }

    static let fullHD = DisplayCase(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1, center: PixelPoint(x: 959, y: 539))
    static let oddAt1x = DisplayCase(frame: CGRect(x: 0, y: 0, width: 1365, height: 767), scale: 1, center: PixelPoint(x: 682, y: 383))
    /// 3840 x 2160 pixels that look like 1920 x 1080.
    static let fullHDAt2x = DisplayCase(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2, center: PixelPoint(x: 1919, y: 1079))
    /// 2731 x 1535 pixels. Real displays are whole points, so a 2x one is always even; this checks the math
    /// for an edge on a half point.
    static let oddAt2x = DisplayCase(frame: CGRect(x: 0, y: 0, width: 1365.5, height: 767.5), scale: 2, center: PixelPoint(x: 1365, y: 767))
    /// Down and to the left of the main display, as a MacBook beside a monitor: 2294 x 1490 pixels.
    static let builtInAt2x = DisplayCase(frame: CGRect(x: -1147, y: -607, width: 1147, height: 745), scale: 2, center: PixelPoint(x: 1146, y: 744))
    /// To the right of the main display, and higher.
    static let rightAt1x = DisplayCase(frame: CGRect(x: 1920, y: 200, width: 2560, height: 1440), scale: 1, center: PixelPoint(x: 1279, y: 719))

    static let all = [fullHD, oddAt1x, fullHDAt2x, oddAt2x, builtInAt2x, rightAt1x]
}

/// The panel's top-left pixel on its display's pixel grid. Nil when the panel isn't on that grid.
private func gridOrigin(of frame: CGRect, on display: DisplayCase) -> PixelPoint? {
    let left = (frame.minX - display.frame.minX) * display.scale
    let top = (display.frame.maxY - frame.maxY) * display.scale
    guard left == left.rounded(), top == top.rounded() else { return nil }
    return PixelPoint(x: Int(left), y: Int(top))
}

/// Where a one-pixel plus's lines cross: the column and the row with the most opaque pixels.
private func lineCrossing(in bitmap: RGBABitmap) -> PixelPoint? {
    var columns = [Int](repeating: 0, count: bitmap.width)
    var rows = [Int](repeating: 0, count: bitmap.height)
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width where bitmap[x, y][3] == 255 {
            columns[x] += 1
            rows[y] += 1
        }
    }
    guard let x = columns.indices.max(by: { columns[$0] < columns[$1] }),
          let y = rows.indices.max(by: { rows[$0] < rows[$1] }), columns[x] > 0 else { return nil }
    return PixelPoint(x: x, y: y)
}

/// A one-pixel plus with nothing around it, so its center pixel is easy to find.
private var thinPlus: CrosshairSettings {
    var settings = CrosshairSettings.defaultValue
    settings.size = 6
    settings.thickness = 1
    settings.outlineEnabled = false
    settings.offsetX = 0
    settings.offsetY = 0
    return settings
}

/// Settings that exercise every part of the sprite: the default, translucent antialiased edges, an even
/// size and a thick outline.
let sampleSettings: [CrosshairSettings] = {
    var x = CrosshairSettings.defaultValue
    x.shape = .x
    x.size = 9
    x.thickness = 2
    x.gap = 2
    x.fillHex = "#FF3B30"
    x.outlineHex = "#1E1E1E"
    x.outlineWidth = 1
    x.opacityPercent = 60
    x.offsetX = 3
    x.offsetY = 2
    var dot = CrosshairSettings.defaultValue
    dot.shape = .dot
    dot.size = 10
    dot.fillHex = "#34C759"
    dot.outlineEnabled = false
    dot.offsetX = 0
    dot.offsetY = 0
    var circle = CrosshairSettings.defaultValue
    circle.shape = .circle
    circle.size = 15
    circle.thickness = 2
    circle.fillHex = "#FFD60A"
    circle.outlineHex = "#0000FF"
    circle.outlineWidth = 3
    circle.offsetX = -5
    circle.offsetY = 4
    return [.defaultValue, x, dot, circle]
}()

@MainActor
@Suite("Crosshair on screen", .serialized)
struct CrosshairOnScreenTests {
    // The overlay's bitmap is the sprite, pixel for pixel, with its hot pixel on the center pixel plus the
    // offset, and nothing else. Regression: on a 2x display the panel's content was sized in pixels as if they
    // were points, so the sprite was drawn twice as large, half a pixel up and to the left, and cut off by
    // the panel's edges.
    @Test(arguments: [DisplayCase.fullHD, .fullHDAt2x])
    func theOverlayDrawsEachSpritePixelOnOneDisplayPixel(display: DisplayCase) throws {
        for settings in sampleSettings {
            let overlay = renderOverlay(settings, displays: [display.info])
            let sprite = CrosshairRenderer.builtIn(settings: settings)
            let spritePixels = RGBABitmap(sprite.image)
            let panel = try #require(gridOrigin(of: overlay.frame, on: display))
            let left = display.center.x + settings.offsetX - sprite.hot.x - panel.x
            let top = display.center.y + settings.offsetY - sprite.hot.y - panel.y
            var wrong = [PixelPoint]()
            for y in 0..<overlay.bitmap.height {
                for x in 0..<overlay.bitmap.width {
                    let expected = spritePixels[x - left, y - top]
                    if !overlay.bitmap.pixel(x: x, y: y, matches: expected) { wrong.append(PixelPoint(x: x, y: y)) }
                }
            }
            #expect(wrong.isEmpty, "\(settings.shape): \(wrong.count) pixels differ from the sprite, first \(wrong.prefix(3))")
        }
    }

    @Test(arguments: DisplayCase.all, [(0, 0), (-1, -1), (6, -3)])
    func theHotPixelLandsOnTheCenterPixelPlusTheOffset(display: DisplayCase, offset: (Int, Int)) throws {
        var settings = thinPlus
        (settings.offsetX, settings.offsetY) = offset
        let overlay = renderOverlay(settings, displays: [display.info])
        // The panel sits on whole points (AppKit floors anything else) on the display's pixel grid, and
        // covers exactly the bitmap it draws.
        let panel = try #require(gridOrigin(of: overlay.frame, on: display))
        #expect(overlay.frame.integral == overlay.frame)
        #expect(display.frame.contains(overlay.frame))
        #expect(overlay.frame.width * display.scale == CGFloat(overlay.bitmap.width))
        #expect(overlay.frame.height * display.scale == CGFloat(overlay.bitmap.height))
        let crossing = try #require(lineCrossing(in: overlay.bitmap))
        #expect(PixelPoint(x: panel.x + crossing.x, y: panel.y + crossing.y)
            == PixelPoint(x: display.center.x + offset.0, y: display.center.y + offset.1))
    }

    // Every display of a multi-display setup, each picked in turn as the crosshair's display.
    @Test func eachDisplayOfASetupGetsItsOwnCenter() throws {
        let cases = [DisplayCase.fullHDAt2x, .builtInAt2x, .rightAt1x]
        let displays = cases.enumerated().map { index, display in
            syntheticDisplay(id: UInt32(index + 1), frame: display.frame, scale: display.scale, isMain: index == 0)
        }
        for (index, display) in cases.enumerated() {
            var settings = thinPlus
            settings.displayChoice = .specific
            settings.specificDisplayID = UInt32(index + 1)
            let overlay = renderOverlay(settings, displays: displays)
            let panel = try #require(gridOrigin(of: overlay.frame, on: display))
            let crossing = try #require(lineCrossing(in: overlay.bitmap))
            #expect(PixelPoint(x: panel.x + crossing.x, y: panel.y + crossing.y) == display.center, "\(display.testDescription)")
        }
    }

    // A 2 px line has no middle pixel: it covers the center pixel and the one after it, so on an even display
    // it straddles the true middle exactly.
    @Test(arguments: [DisplayCase.fullHD, .fullHDAt2x])
    func anEvenLineStraddlesTheMiddleOfAnEvenDisplay(display: DisplayCase) throws {
        var settings = thinPlus
        settings.thickness = 2
        let overlay = renderOverlay(settings, displays: [display.info])
        let panel = try #require(gridOrigin(of: overlay.frame, on: display))
        let bounds = try #require(overlay.bitmap.opaqueBounds)
        let columns = (0..<overlay.bitmap.width).filter { x in overlay.bitmap[x, bounds.minY][3] > 0 }.map { panel.x + $0 }
        let rows = (0..<overlay.bitmap.height).filter { y in overlay.bitmap[bounds.minX, y][3] > 0 }.map { panel.y + $0 }
        #expect(columns == [display.center.x, display.center.x + 1])
        #expect(rows == [display.center.y, display.center.y + 1])
    }

    // Minecraft draws its 15-unit crosshair at `(width - 15) / 2` whole GUI units, rounded down, so at GUI
    // scale 3 its center line covers these display pixels. On a 2x display Minecraft renders in pixels
    // (3840 x 2160 for a display that looks like 1920 x 1080), so its GUI is 1280 x 720 units.
    private func minecraftCenterLine(pixels: Int, guiScale: Int = 3) -> [Int] {
        let start = ((pixels / guiScale - 15) / 2 + 7) * guiScale
        return Array(start..<start + guiScale)
    }

    @Test(arguments: [DisplayCase.fullHD, .fullHDAt2x])
    func theDrawnDefaultCoversMinecraftsCrosshairAtGUIScaleThree(display: DisplayCase) throws {
        let overlay = renderOverlay(.defaultValue, displays: [display.info])
        let panel = try #require(gridOrigin(of: overlay.frame, on: display))
        let white: [UInt8] = [255, 255, 255, 255]
        var whiteColumns = Set<Int>(), whiteRows = Set<Int>()
        for y in 0..<overlay.bitmap.height {
            for x in 0..<overlay.bitmap.width where overlay.bitmap.pixel(x: x, y: y, matches: white) {
                whiteColumns.insert(x)
                whiteRows.insert(y)
            }
        }
        // The vertical arm's columns, in the white fill's top row, and the horizontal arm's rows, in its left column.
        let top = try #require(whiteRows.min()), left = try #require(whiteColumns.min())
        let columns = (0..<overlay.bitmap.width).filter { overlay.bitmap.pixel(x: $0, y: top, matches: white) }.map { panel.x + $0 }
        let rows = (0..<overlay.bitmap.height).filter { overlay.bitmap.pixel(x: left, y: $0, matches: white) }.map { panel.y + $0 }
        let pixels = CrosshairGeometry.gridSize(frame: display.frame, scale: display.scale)
        #expect(columns == minecraftCenterLine(pixels: pixels.width))
        #expect(rows == minecraftCenterLine(pixels: pixels.height))
    }
}
