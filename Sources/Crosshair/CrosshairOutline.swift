import Foundation

/// Grows a coverage mask outward to make a solid outline mask the same size, so the outline can be
/// drawn first and the fill composited on top.
enum CrosshairOutline {
    /// `mask` dilated by `width` pixels in every direction (a max-filter over a disc): each pixel takes the highest
    /// coverage within `width` pixels of it.
    ///
    /// A disc is a stack of rows, each reaching some pixels to either side, so the filter runs in two passes: first the
    /// highest value in every row window a disc row needs, then the highest of the disc's rows. That gives the same pixels
    /// as looking at every point of the disc, in a few passes over the mask instead of one per point, which keeps the 4×
    /// images of a large Custom Cursor quick.
    static func dilated(_ mask: CrosshairMask, width: Int) -> CrosshairMask {
        guard width > 0 else { return mask }
        let (columns, rows) = (mask.width, mask.height)
        let limit = Double(width * width) + 0.0001
        // How far each disc row reaches to either side.
        let reaches = (-width...width).map { dy in
            var reach = 0
            while Double((reach + 1) * (reach + 1) + dy * dy) <= limit { reach += 1 }
            return reach
        }
        // windows[reach][i]: the highest value in pixel i's row, `reach` pixels either side of it.
        var windows = [mask.alpha]
        windows.reserveCapacity(width + 1)
        for reach in 1...width {
            var grown = windows[reach - 1]
            mask.alpha.withUnsafeBufferPointer { source in
                grown.withUnsafeMutableBufferPointer { out in
                    for y in 0..<rows {
                        let row = y * columns
                        for x in 0..<columns {
                            var value = out[row + x]
                            if x - reach >= 0 { value = max(value, source[row + x - reach]) }
                            if x + reach < columns { value = max(value, source[row + x + reach]) }
                            out[row + x] = value
                        }
                    }
                }
            }
            windows.append(grown)
        }
        var alpha = [UInt8](repeating: 0, count: columns * rows)
        alpha.withUnsafeMutableBufferPointer { out in
            for (index, reach) in reaches.enumerated() {
                let dy = index - width
                windows[reach].withUnsafeBufferPointer { window in
                    for y in max(0, -dy)..<min(rows, rows - dy) {
                        let target = y * columns
                        let source = (y + dy) * columns
                        for x in 0..<columns where window[source + x] > out[target + x] {
                            out[target + x] = window[source + x]
                        }
                    }
                }
            }
        }
        return CrosshairMask(width: columns, height: rows, alpha: alpha, hot: mask.hot)
    }
}
