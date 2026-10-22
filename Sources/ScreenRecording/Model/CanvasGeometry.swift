import Foundation

/// A rectangle on the canvas as fractions of the canvas's width and height, with a top-left origin: (0, 0) is the
/// canvas's top-left corner and (1, 1) its bottom-right. Layouts are saved this way, so a source keeps its place
/// and size whatever the canvas's pixel size: Minecraft's display at another resolution or backing scale (1x or
/// 2x, a scaled mode, another monitor), a custom canvas, or any output size.
public struct CanvasRect: Codable, Equatable, Hashable, Sendable {
    /// The smallest a source may be: 16 pixels of a 1920 x 1080 canvas, on each axis.
    public static let minimumWidth = 16.0 / 1920
    public static let minimumHeight = 16.0 / 1080

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Moved and shrunk until it lies inside the canvas and is at least the minimum size; values that aren't
    /// finite fall back to the top-left corner and the minimum size.
    public func clamped() -> CanvasRect {
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
        let width = min(1, max(Self.minimumWidth, finite(width, Self.minimumWidth)))
        let height = min(1, max(Self.minimumHeight, finite(height, Self.minimumHeight)))
        let x = min(1 - width, max(0, finite(x, 0)))
        let y = min(1 - height, max(0, finite(y, 0)))
        return CanvasRect(x: x, y: y, width: width, height: height)
    }
}

/// The one mapping between a layout's fractions and a surface the canvas is drawn on: canvas pixels for the
/// editor's drag math, output pixels for the compositor, points for the editor's plate. They all go through here,
/// so the preview, the outlines drawn over it and the recording always agree, at any size or backing scale.
public struct CanvasMapping: Equatable, Sendable {
    /// The surface's size, in its own units.
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: PixelSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }

    /// Where `rect` lands on this surface.
    public func rect(_ rect: CanvasRect) -> PixelRect {
        PixelRect(x: rect.x * width, y: rect.y * height, width: rect.width * width, height: rect.height * height)
    }

    /// The fractions of a rectangle given in this surface's units.
    public func canvasRect(_ rect: PixelRect) -> CanvasRect {
        let w = width > 0 ? width : 1, h = height > 0 ? height : 1
        return CanvasRect(x: rect.x / w, y: rect.y / h, width: rect.width / w, height: rect.height / h)
    }

    /// Lengths that belong to neither axis (corner radius, border width) are fractions of the canvas's shorter side.
    public var shorterSide: Double { min(width, height) }

    /// A length saved as a fraction of the shorter side, in this surface's units.
    public func length(_ fraction: Double) -> Double { fraction * shorterSide }

    /// A length in this surface's units as a fraction of the shorter side.
    public func fraction(ofLength length: Double) -> Double { shorterSide > 0 ? length / shorterSide : 0 }
}
