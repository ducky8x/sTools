import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal

public enum CompositorError: Error, Equatable {
    case noMetalDevice
    case poolCreationFailed
}

/// Words for the page's note when a recording can't start (spec 5.4.4), instead of an error number.
extension CompositorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noMetalDevice: "This Mac has no Metal device to put the video together with."
        case .poolCreationFailed: "sTools couldn\u{2019}t set aside memory for the video."
        }
    }
}

/// Draws one output frame from a `CompositionPlan` with Core Image on Metal, into buffers from a pool
/// (spec 5.4.2: crop, scale, opacity, rounded corners, borders; no custom shaders). Call from one queue.
public final class Compositor: @unchecked Sendable {
    public let outputSize: PixelSize

    private let context: CIContext
    private let pool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(outputSize: PixelSize) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CompositorError.noMetalDevice }
        let size = outputSize.evenSized
        self.outputSize = size
        context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attributes as CFDictionary, &pool)
        guard let pool else { throw CompositorError.poolCreationFailed }
        self.pool = pool
    }

    /// Renders `plan` with each layer's latest frame into a fresh pooled buffer; nil if the pool is exhausted.
    public func render(_ plan: CompositionPlan, frames: [SourceKey: VideoFrame]) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        let extent = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        var image = CIImage(color: .black).cropped(to: extent)
        for layer in plan.layers {
            guard let frame = frames[layer.key], let drawn = draw(layer, from: frame) else { continue }
            image = drawn.composited(over: image)
        }
        context.render(image, to: buffer, bounds: extent, colorSpace: colorSpace)
        return buffer
    }

    /// The same composite as an image, for the page's live preview.
    public func renderImage(_ plan: CompositionPlan, frames: [SourceKey: VideoFrame]) -> CGImage? {
        guard let buffer = render(plan, frames: frames) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        return context.createCGImage(CIImage(cvPixelBuffer: buffer), from: extent)
    }

    /// One layer, already placed in output coordinates (Core Image's bottom-left origin).
    private func draw(_ layer: CompositionPlan.Layer, from frame: VideoFrame) -> CIImage? {
        let bufferHeight = Double(CVPixelBufferGetHeight(frame.pixelBuffer))
        let source = layer.sourceRect
        guard source.width > 0, source.height > 0, layer.destination.width > 0, layer.destination.height > 0 else { return nil }

        let crop = CGRect(x: source.x, y: bufferHeight - source.maxY, width: source.width, height: source.height)
        let destination = CGRect(
            x: layer.destination.x, y: Double(outputSize.height) - layer.destination.maxY,
            width: layer.destination.width, height: layer.destination.height)
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: destination.width / crop.width, y: destination.height / crop.height))
            .transformed(by: CGAffineTransform(translationX: destination.minX, y: destination.minY))
            .cropped(to: destination)

        if layer.opacity < 1 {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity))
            image = matrix.outputImage ?? image
        }
        let radius = min(layer.cornerRadius, min(destination.width, destination.height) / 2)
        if radius > 0.5 {
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = destination
            mask.radius = Float(radius)
            mask.color = .white
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = image
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = mask.outputImage
            image = blend.outputImage ?? image
        }
        if layer.borderWidth > 0.5 {
            // The generator strokes inward from the extent's edge, so the border lies inside the source.
            let stroke = CIFilter.roundedRectangleStrokeGenerator()
            stroke.extent = destination
            stroke.radius = Float(radius)
            stroke.width = Float(layer.borderWidth)
            stroke.color = Self.color(hex: layer.borderColorHex)
            if let border = stroke.outputImage { image = border.composited(over: image) }
        }
        return image
    }

    /// `#RRGGBB` or `#RRGGBBAA`; anything else is white.
    static func color(hex: String) -> CIColor {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return .white }
        let hasAlpha = text.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? .white
    }
}
