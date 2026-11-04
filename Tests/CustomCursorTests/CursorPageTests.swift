import AppKit
import STDesign
import SwiftUI
import Testing
@testable import CustomCursor

/// Draws `view` at `scale` into a bitmap inside a window that is never ordered in.
@MainActor
private func render<V: View>(_ view: V, size: CGSize, scale: CGFloat) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.displayScale, scale))
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    window.contentView = nil
    return rep
}

/// The bounds, in pixels, of the pixels `matches` picks.
private func bounds(in rep: NSBitmapImageRep, where matches: (NSColor) -> Bool) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    var result: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), matches(color) else { continue }
            result = (min(result?.minX ?? x, x), min(result?.minY ?? y, y), max(result?.maxX ?? x, x), max(result?.maxY ?? y, y))
        }
    }
    return result
}

private func isWhite(_ color: NSColor) -> Bool {
    color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95
}

private func isGold(_ color: NSColor) -> Bool {
    color.redComponent > 0.75 && color.greenComponent > 0.55 && color.blueComponent < 0.45
}

@MainActor
@Suite("Custom Cursor: the page")
struct CursorPageTests {
    /// The preview shows the pointer at its real size: a 12 pt dot covers 24 pixels across on a 2× display.
    @Test func thePreviewIsTheRealSize() throws {
        var settings = CustomCursorSettings()
        settings.outlineEnabled = false
        let cursor = CursorArt.cursor(for: settings, image: nil, scales: [2])
        let rep = render(CursorPreview(cursor: cursor, scale: 2), size: CGSize(width: 300, height: CursorPreview.height), scale: 2)
        let white = try #require(bounds(in: rep, where: isWhite))
        #expect(white.maxX - white.minX + 1 == 24)
        #expect(white.maxY - white.minY + 1 == 24)
    }

    /// The gold mark sits on the click point: the dot's middle, here, between its middle pixels.
    @Test func theMarkIsOnTheClickPoint() throws {
        var settings = CustomCursorSettings()
        settings.outlineEnabled = false
        let cursor = try #require(CursorArt.cursor(for: settings, image: nil, scales: [2]))
        let size = CGSize(width: 300, height: CursorPreview.height)
        let rep = render(CursorPreview(cursor: cursor, scale: 2), size: size, scale: 2)
        let white = try #require(bounds(in: rep, where: isWhite))
        let gold = try #require(bounds(in: rep, where: isGold))
        // The ticks aim at the click point from the left and from above, outside the pointer.
        #expect(gold.minX < white.minX)
        #expect(gold.minY < white.minY)
        let middleX = Double(white.minX + white.maxX + 1) / 2
        let middleY = Double(white.minY + white.maxY + 1) / 2
        // The dot on the click point: gold right at the middle.
        let center = try #require(rep.colorAt(x: Int(middleX), y: Int(middleY))?.usingColorSpace(.deviceRGB))
        #expect(isGold(center))
    }

    @Test func withNothingToDrawThePreviewIsEmpty() {
        let rep = render(CursorPreview(cursor: nil, scale: 2), size: CGSize(width: 300, height: CursorPreview.height), scale: 2)
        #expect(bounds(in: rep, where: isWhite) == nil)
        #expect(bounds(in: rep, where: isGold) == nil)
    }

    @Test func thePagesWords() {
        #expect(CustomCursorSettingsView.Copy.notSupported
            == "Custom Cursor can\u{2019}t change the pointer on this version of macOS, so it stays off.")
        #expect(CustomCursorSettingsView.Copy.otherApps
            == "When sTools puts your arrow back, it can also reset pointers another cursor app such as Mousecape changed. "
            + "Apply them again from that app.")
        #expect(CursorPreview.spokenLabel == "Pointer preview. The gold mark is the point that clicks.")
        #expect(CustomCursorSettingsView.shapes.map(\.title) == ["Plus", "Dot", "Circle", "X", "Image"])
        #expect(CursorImageRows.clickPoints.map(\.title) == ["Center", "Top left", "Top right", "Bottom left", "Bottom right"])
    }

    /// The page lays out with every shape and without the calls, at the window's narrowest column.
    @Test(arguments: [CustomCursorSettings.Shape.dot, .plus, .image])
    func thePageRenders(shape: CustomCursorSettings.Shape) {
        _ = STFont.register()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()),
                                                swapper: FakeCursorSwapper(isSupported: shape != .plus))
        controller.settings.shape = shape
        let rep = render(CustomCursorSettingsView(controller: controller).environment(\.stTheme, STTheme()),
                         size: CGSize(width: 395, height: 700), scale: 1)
        #expect(bounds(in: rep, where: isWhite) != nil)
    }
}
