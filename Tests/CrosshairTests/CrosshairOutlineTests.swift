import Foundation
import Testing
@testable import Crosshair

/// The outline is the mask grown by a disc: each pixel takes the highest coverage within `width` pixels of it.
@Suite struct CrosshairOutlineTests {
    /// The definition, one disc per pixel, for comparison.
    private func reference(_ mask: CrosshairMask, width: Int) -> CrosshairMask {
        var alpha = [UInt8](repeating: 0, count: mask.width * mask.height)
        let limit = Double(width * width) + 0.0001
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                var best: UInt8 = 0
                for dy in -width...width {
                    for dx in -width...width where Double(dx * dx + dy * dy) <= limit {
                        best = max(best, mask.coverage(x: x + dx, y: y + dy))
                    }
                }
                alpha[y * mask.width + x] = best
            }
        }
        return CrosshairMask(width: mask.width, height: mask.height, alpha: alpha, hot: mask.hot)
    }

    @Test(arguments: [1, 2, 3, 5, 8, 16])
    func itIsTheDiscMaxFilterExactly(width: Int) {
        var generator = SeededGenerator(seed: UInt64(width))
        let size = 3 * width + 7
        // Mostly clear with scattered coverage, as an antialiased shape's edge is.
        let alpha = (0..<(size * (size + 3))).map { _ in UInt8.random(in: 0...255, using: &generator) > 230 ? UInt8.random(in: 1...255, using: &generator) : 0 }
        let mask = CrosshairMask(width: size, height: size + 3, alpha: alpha, hot: PixelPoint(x: 1, y: 2))
        #expect(CrosshairOutline.dilated(mask, width: width) == reference(mask, width: width))
    }

    @Test(arguments: [CrosshairSettings.Shape.plus, .dot, .circle, .x])
    func itIsTheDiscMaxFilterOnEveryShape(shape: CrosshairSettings.Shape) {
        let mask = CrosshairShapeMath.mask(shape: shape, size: 11, thickness: 3, gap: 1, margin: 4)
        #expect(CrosshairOutline.dilated(mask, width: 4) == reference(mask, width: 4))
    }
}

/// A small deterministic random number generator (SplitMix64), so a failure can be run again exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
