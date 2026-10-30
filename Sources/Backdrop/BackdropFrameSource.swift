import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The frames of one GIF, each decoded when asked for. Tests pass made-up frames.
protocol BackdropFrameSource: Sendable {
    var frameCount: Int { get }
    /// The picture's size in pixels.
    var size: CGSize { get }
    /// How long frame `index` stays up, in seconds.
    func delay(at index: Int) -> TimeInterval
    /// Decodes frame `index` to a bitmap that is ready to draw. It blocks, so call it off the main actor. Nil when the
    /// frame can't be decoded.
    func frame(at index: Int) -> CGImage?
}

/// A GIF read with ImageIO. ImageIO draws each frame whole, with the frames before it already applied (disposal
/// methods and partial frames included), so a frame is a complete picture. Asking for the frames in order is cheapest.
final class ImageIOFrameSource: BackdropFrameSource, @unchecked Sendable {
    let frameCount: Int
    let size: CGSize
    private let delays: [TimeInterval]
    private let source: CGImageSource
    /// ImageIO is thread-safe, but decoding one frame at a time is also how it's fastest, so the frames queue up here.
    private let lock = NSLock()

    /// What browsers do: a frame that asks for no time, or one hundredth of a second, gets a tenth of a second, so a
    /// GIF made for a slow machine doesn't run flat out.
    static func displayDelay(_ delay: TimeInterval) -> TimeInterval { delay > 0.01 ? delay : 0.1 }

    /// The most pixels one frame may have, 4096 x 4096. A decoded frame is four bytes a pixel, and a few are held at once,
    /// so a GIF past this could take gigabytes.
    static let maximumPixels = 4096 * 4096

    /// Opens the GIF at `url` without decoding any picture. Nil when it isn't a GIF, has no frames, has frames over
    /// `maximumPixels`, or can't be read.
    static func open(at url: URL, maximumPixels: Int = ImageIOFrameSource.maximumPixels) -> ImageIOFrameSource? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), type as String == UTType.gif.identifier,
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = first[kCGImagePropertyPixelWidth] as? Int, let height = first[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maximumPixels else { return nil }
        let delays = (0..<count).map { index -> TimeInterval in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            return displayDelay(delay)
        }
        return ImageIOFrameSource(source: source, count: count, size: CGSize(width: width, height: height), delays: delays)
    }

    private init(source: CGImageSource, count: Int, size: CGSize, delays: [TimeInterval]) {
        self.source = source
        frameCount = count
        self.size = size
        self.delays = delays
    }

    func delay(at index: Int) -> TimeInterval { delays.indices.contains(index) ? delays[index] : 0.1 }

    func frame(at index: Int) -> CGImage? {
        guard (0..<frameCount).contains(index) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Decoded now, here, so drawing it later costs no decoding on the main thread.
        return CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
