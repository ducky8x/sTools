import Foundation

/// Grows a coverage mask outward to make a solid outline mask the same size, so the outline can be
/// drawn first and the fill composited on top.
enum CrosshairOutline {
    /// `mask` dilated by `width` pixels in every direction (a simple max-filter over a disc).
    static func dilated(_ mask: CrosshairMask, width: Int) -> CrosshairMask {
        guard width > 0 else { return mask }
        var alpha = [UInt8](repeating: 0, count: mask.width * mask.height)
        let radius = width
        let radiusSquared = Double(radius) * Double(radius)
        var offsets: [(Int, Int)] = []
        for dy in -radius...radius {
            for dx in -radius...radius where Double(dx * dx + dy * dy) <= radiusSquared + 0.0001 {
                offsets.append((dx, dy))
            }
        }
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                var best: UInt8 = 0
                for (dx, dy) in offsets {
                    let value = mask.coverage(x: x + dx, y: y + dy)
                    if value > best {
                        best = value
                        if best == 255 { break }
                    }
                }
                alpha[y * mask.width + x] = best
            }
        }
        return CrosshairMask(width: mask.width, height: mask.height, alpha: alpha, hot: mask.hot)
    }
}
