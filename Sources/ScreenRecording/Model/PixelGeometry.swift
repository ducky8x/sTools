import CoreGraphics
import Foundation

/// A size in whole pixels.
public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var aspectRatio: Double { height > 0 ? Double(width) / Double(height) : 1 }
    public var cgSize: CGSize { CGSize(width: width, height: height) }

    /// The size with both sides rounded down to even numbers (H.264 and HEVC need even sides).
    public var evenSized: PixelSize {
        PixelSize(width: max(2, width & ~1), height: max(2, height & ~1))
    }
}

/// A rectangle in pixels. The origin is the top-left corner and y grows downward,
/// which is how the canvas editor and image buffers address pixels.
public struct PixelRect: Codable, Equatable, Hashable, Sendable {
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

    public init(origin: (x: Double, y: Double), size: PixelSize) {
        self.init(x: origin.x, y: origin.y, width: Double(size.width), height: Double(size.height))
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    /// Rounds the edges to whole pixels (the left/top edge down, the right/bottom edge to nearest).
    public var pixelAligned: PixelRect {
        let left = x.rounded(), top = y.rounded()
        let right = maxX.rounded(), bottom = maxY.rounded()
        return PixelRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    public func scaled(by factor: Double) -> PixelRect {
        PixelRect(x: x * factor, y: y * factor, width: width * factor, height: height * factor)
    }

    public func offsetBy(dx: Double, dy: Double) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}
