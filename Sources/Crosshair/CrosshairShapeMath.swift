import Foundation

/// Which points a built-in shape covers, measured in pixels from the shape's center point.
enum CrosshairShapeMath {
    static let supersampling = 4

    /// Pixels from the center point to the farthest covered point along either axis.
    static func halfExtent(shape: CrosshairSettings.Shape, size: Int, thickness: Int, gap: Int) -> Double {
        let size = Double(size), thickness = Double(thickness), gap = Double(gap)
        switch shape {
        case .plus: return thickness / 2 + gap + size
        case .dot, .circle: return size / 2
        case .x: return (gap + size + thickness / 2) / 2.0.squareRoot()
        case .image: return 0
        }
    }

    /// Where the center point sits inside the hot pixel, as a fraction of a pixel from its left/top edge.
    /// An odd length centers on a pixel (0.5). An even length has no center pixel; the hot pixel is the one
    /// just left of (or above) the center (`CrosshairGeometry.centerIndex`), so the center is its right edge.
    static func centerFraction(shape: CrosshairSettings.Shape, size: Int, thickness: Int) -> Double {
        centeringLength(shape: shape, size: size, thickness: thickness) % 2 != 0 ? 0.5 : 1
    }

    /// The width that decides where a shape's middle falls: the line thickness for Plus and X, the
    /// diameter for Dot and Circle.
    static func centeringLength(shape: CrosshairSettings.Shape, size: Int, thickness: Int) -> Int {
        (shape == .plus || shape == .x) ? thickness : size
    }

    /// Whether the point (u, v), relative to the center point (y grows downward), is covered.
    static func covers(shape: CrosshairSettings.Shape, size: Int, thickness: Int, gap: Int, u: Double, v: Double) -> Bool {
        let half = Double(thickness) / 2
        let size = Double(size), gap = Double(gap)
        switch shape {
        case .plus:
            let au = abs(u), av = abs(v)
            if gap == 0, au <= half, av <= half { return true }
            let horizontal = av <= half && au >= half + gap && au <= half + gap + size
            let vertical = au <= half && av >= half + gap && av <= half + gap + size
            return horizontal || vertical
        case .dot:
            return (u * u + v * v).squareRoot() <= size / 2
        case .circle:
            let radius = (u * u + v * v).squareRoot()
            return radius <= size / 2 && radius >= max(0, size / 2 - Double(thickness))
        case .x:
            let root = 2.0.squareRoot()
            let diagonals = [((u + v) / root, (u - v) / root), ((u - v) / root, (u + v) / root)]
            return diagonals.contains { along, perpendicular in
                abs(perpendicular) <= half && abs(along) >= gap && abs(along) <= gap + size
            }
        case .image:
            return false
        }
    }

    /// The shape's coverage mask with `margin` empty pixels on every side (room for an outline).
    static func mask(shape: CrosshairSettings.Shape, size: Int, thickness: Int, gap: Int,
                     margin: Int) -> CrosshairMask {
        let reach = Int(halfExtent(shape: shape, size: size, thickness: thickness, gap: gap).rounded(.up))
        let radius = reach + max(margin, 0) + 1
        let canvas = 2 * radius + 2
        let center = Double(radius) + centerFraction(shape: shape, size: size, thickness: thickness)
        let samples = supersampling
        var alpha = [UInt8](repeating: 0, count: canvas * canvas)
        for py in 0..<canvas {
            for px in 0..<canvas {
                var inside = 0
                for sy in 0..<samples {
                    for sx in 0..<samples {
                        let u = Double(px) + (Double(sx) + 0.5) / Double(samples) - center
                        let v = Double(py) + (Double(sy) + 0.5) / Double(samples) - center
                        if covers(shape: shape, size: size, thickness: thickness, gap: gap, u: u, v: v) { inside += 1 }
                    }
                }
                alpha[py * canvas + px] = UInt8((Double(inside) / Double(samples * samples) * 255).rounded())
            }
        }
        return CrosshairMask(width: canvas, height: canvas, alpha: alpha, hot: PixelPoint(x: radius, y: radius))
    }
}
