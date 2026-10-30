import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Backdrop

// What the animated-fill tests share: a wait that never blocks the main actor, a clock they move by hand, and media
// generated into temporary folders (no file from the owner's disk, nothing on screen).

/// Waits, without blocking the main actor, until `condition` holds or `seconds` of awake time pass. True when it held.
@MainActor
func waitUntil(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: .seconds(seconds))
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A folder that is removed again when the test is over.
final class TempFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "sTools-backdrop-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

/// A clock the test moves by hand; its timers fire in order as it passes them.
@MainActor
final class FakeFrameClock: BackdropFrameClock {
    final class FakeTimer: BackdropFrameTimer {
        let due: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false
        var hasFired = false
        init(due: TimeInterval, action: @escaping @MainActor () -> Void) { self.due = due; self.action = action }
        func cancel() { isCancelled = true }
    }

    var now: TimeInterval = 1_000
    private(set) var timers: [FakeTimer] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any BackdropFrameTimer {
        let timer = FakeTimer(due: now + delay, action: action)
        timers.append(timer)
        return timer
    }

    /// Timers neither fired nor cancelled.
    var waiting: [FakeTimer] { timers.filter { !$0.isCancelled && !$0.hasFired } }

    /// Moves time forward, firing each timer that comes due on the way, in order.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = waiting.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            now = next.due
            next.hasFired = true
            next.action()
        }
        now = end
    }
}

/// An sRGB color as bytes.
struct RGB: Equatable, CustomStringConvertible {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    static let red = RGB(255, 0, 0), green = RGB(0, 255, 0), blue = RGB(0, 0, 255), yellow = RGB(255, 255, 0)
    var description: String { "rgb(\(r), \(g), \(b))" }

    /// Whether each channel is within `tolerance` of `other`'s (video codecs change colors a little).
    func isClose(to other: RGB, tolerance: Int = 24) -> Bool {
        abs(Int(r) - Int(other.r)) <= tolerance && abs(Int(g) - Int(other.g)) <= tolerance && abs(Int(b) - Int(other.b)) <= tolerance
    }
}

enum TestMedia {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func solidImage(_ color: RGB, width: Int = 16, height: Int = 12) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: srgb, components: [CGFloat(color.r) / 255, CGFloat(color.g) / 255, CGFloat(color.b) / 255, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The color of the pixel at `(x, y)` (from the top left) of `image`, drawn into sRGB.
    static func color(of image: CGImage, x: Int = 0, y: Int = 0) -> RGB {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return RGB(bytes[0], bytes[1], bytes[2])
    }

    /// A GIF of one solid-color frame per color, each up for the delay at the same position in `delays`.
    @discardableResult
    static func writeGIF(to url: URL, colors: [RGB], delays: [Double], width: Int = 16, height: Int = 12) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (color, delay) in zip(colors, delays) {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(destination, solidImage(color, width: width, height: height), properties as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination), "the test GIF wasn't written")
        return url
    }

    /// A short movie of solid-color pictures, `framesPerColor` of each color, with no sound.
    @discardableResult
    static func writeMovie(to url: URL, colors: [RGB], framesPerColor: Int = 5, framesPerSecond: Int32 = 10,
                           width: Int = 128, height: Int = 96, codec: AVVideoCodecType = .h264,
                           fileType: AVFileType = .mp4, transform: CGAffineTransform = .identity) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        input.transform = transform
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var index: Int64 = 0
        let clock = SuspendingClock()
        for color in colors {
            let buffer = try pixelBuffer(color, width: width, height: height)
            for _ in 0..<framesPerColor {
                let deadline = clock.now.advanced(by: .seconds(10))
                while !input.isReadyForMoreMediaData {
                    guard clock.now < deadline else { throw CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: index, timescale: framesPerSecond)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                index += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func pixelBuffer(_ color: RGB, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                base[offset] = color.b
                base[offset + 1] = color.g
                base[offset + 2] = color.r
                base[offset + 3] = 255
            }
        }
        return buffer
    }
}

/// A player that only records what it was told, for the tests of everything around the players.
@MainActor
final class FakePlayer: BackdropPlayer {
    let mediaLayer = CALayer()
    private(set) var naturalSize: CGSize?
    private(set) var failure: String?
    private(set) var calls: [String] = []
    private(set) var isPlaying = false
    private(set) var isStopped = false
    private var observers = BackdropPlayerObservers()

    init(naturalSize: CGSize? = nil, failure: String? = nil) {
        self.naturalSize = naturalSize
        self.failure = failure
    }

    func observe(_ handler: @escaping @MainActor () -> Void) { observers.add(handler) }
    func play() { calls.append("play"); isPlaying = !isStopped }
    func pause() { calls.append("pause"); isPlaying = false }
    func stop() { calls.append("stop"); isPlaying = false; isStopped = true }

    /// The file has been opened and its picture is this big.
    func learn(size: CGSize) { naturalSize = size; observers.notify() }
    /// The file turned out not to play.
    func fail(_ message: String) { failure = message; observers.notify() }
}
