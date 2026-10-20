import AppKit
import CoreGraphics
import STDesign
import SwiftUI

/// A finished crosshair bitmap and the hot pixel that must land on the target pixel.
struct CrosshairSprite {
    var image: CGImage
    var size: PixelSize
    var hot: PixelPoint
}

enum CrosshairRenderer {
    /// Renders the built-in shapes (outline first, fill on top) at `opacityPercent`.
    static func builtIn(settings: CrosshairSettings) -> CrosshairSprite {
        let margin = settings.outlineEnabled ? settings.outlineWidth : 0
        let fillMask = CrosshairShapeMath.mask(
            shape: settings.shape, size: settings.size, thickness: settings.thickness, gap: settings.gap, margin: margin)
        let outlineMask = settings.outlineEnabled ? CrosshairOutline.dilated(fillMask, width: settings.outlineWidth) : nil
        // Composite the outline and fill at full strength first. Blending each layer at a reduced opacity
        // separately would stack their alphas (and mix their colors) instead of giving one uniform result,
        // so the opacity setting is applied once, afterward, to the finished composite.
        let composite = renderFullStrength(width: fillMask.width, height: fillMask.height) { context in
            if let outlineMask {
                draw(outlineMask, color: NSColor(STColorWellHex.color(from: settings.outlineHex)), in: context)
            }
            draw(fillMask, color: NSColor(STColorWellHex.color(from: settings.fillHex)), in: context)
        }
        let image = applyOpacity(settings.opacityPercent, to: composite)
        return CrosshairSprite(image: image, size: PixelSize(width: fillMask.width, height: fillMask.height), hot: fillMask.hot)
    }

    /// Renders a user image scaled by `imageScalePercent`, with the hot pixel at `anchor`.
    static func image(_ source: CGImage, settings: CrosshairSettings) -> CrosshairSprite {
        let scale = Double(settings.imageScalePercent) / 100
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        let hot = CrosshairGeometry.hotPixel(
            spriteSize: PixelSize(width: width, height: height), anchor: settings.imageAnchor)
        let composite = renderFullStrength(width: width, height: height) { context in
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = applyOpacity(settings.opacityPercent, to: composite)
        return CrosshairSprite(image: image, size: PixelSize(width: width, height: height), hot: hot)
    }

    private static func renderFullStrength(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    /// Scales a finished image's alpha by `percent` in one pass, so a partly transparent composite
    /// (antialiased edges, an outline under a fill) dims as a single unit instead of each layer
    /// blending at a reduced opacity and stacking.
    private static func applyOpacity(_ percent: Int, to image: CGImage) -> CGImage {
        guard percent < 100 else { return image }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setAlpha(CGFloat(percent) / 100)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func draw(_ mask: CrosshairMask, color: NSColor, in context: CGContext) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return }
        context.saveGState()
        context.setFillColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1)
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let alpha = mask.coverage(x: x, y: y)
                guard alpha > 0 else { continue }
                context.setAlpha(CGFloat(alpha) / 255)
                // CGContext is bottom-left origin; the mask is top-left origin.
                context.fill(CGRect(x: x, y: mask.height - 1 - y, width: 1, height: 1))
            }
        }
        context.restoreGState()
    }
}
