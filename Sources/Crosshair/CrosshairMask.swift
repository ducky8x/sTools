import Foundation

/// A coverage mask (0...255 per pixel) for a built-in crosshair shape, plus the pixel that must land
/// on the display's center. The canvas is square with the hot pixel at `(radius, radius)`.
struct CrosshairMask: Equatable, Sendable {
    var width: Int
    var height: Int
    var alpha: [UInt8]
    var hot: PixelPoint

    func coverage(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return alpha[y * width + x]
    }
}
