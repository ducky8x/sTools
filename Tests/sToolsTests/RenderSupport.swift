import AppKit
import SwiftUI

/// Renders `view` in an `NSHostingView` into a bitmap at `scale` x, always in the dark appearance.
@MainActor
func renderBitmap<V: View>(_ view: V, size: CGSize, scale: Int = 1) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

/// How many different colors appear; a blank render has one.
func distinctColors(in rep: NSBitmapImageRep) -> Int {
    guard let data = rep.bitmapData else { return 0 }
    let bytesPerPixel = rep.bitsPerPixel / 8
    var seen = Set<UInt32>()
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let offset = y * rep.bytesPerRow + x * bytesPerPixel
            var key: UInt32 = 0
            for channel in 0..<min(bytesPerPixel, 4) { key = key << 8 | UInt32(data[offset + channel]) }
            seen.insert(key)
        }
    }
    return seen.count
}

/// The color of the pixel at `(x, y)` in point coordinates as `[r, g, b]` bytes.
func pixel(in rep: NSBitmapImageRep, x: Int, y: Int) -> [UInt8] {
    guard let data = rep.bitmapData else { return [] }
    let scale = rep.pixelsWide / max(Int(rep.size.width), 1)
    let offset = (y * scale) * rep.bytesPerRow + (x * scale) * (rep.bitsPerPixel / 8)
    return [data[offset], data[offset + 1], data[offset + 2]]
}
