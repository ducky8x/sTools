import CoreGraphics
import Foundation

/// The names macOS draws its arrow by (spec 5.7.1). Since macOS 26 the arrow is registered twice, and AppKit's arrow also
/// resolves through the core cursor name. Only these are replaced; the I-beam, the hands and the rest stay macOS's.
public enum CursorNames {
    public static let arrow = ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowS", "com.apple.cursor.0"]
}

/// One cursor as macOS keeps it registered under a name: its images, size and click point in points, and its frames.
public struct RegisteredCursor: @unchecked Sendable {
    public var name: String
    public var size: CGSize
    public var hotSpot: CGPoint
    public var frameCount: Int
    public var frameDuration: Double
    public var images: [CGImage]

    public init(name: String, size: CGSize, hotSpot: CGPoint, frameCount: Int, frameDuration: Double, images: [CGImage]) {
        self.name = name
        self.size = size
        self.hotSpot = hotSpot
        self.frameCount = frameCount
        self.frameDuration = frameDuration
        self.images = images
    }
}

/// Replaces and restores the pointer macOS draws, for every app (spec 5.7.1). The app uses the window server's private
/// calls (`makeLiveSwapper()`); tests use a fake, because the real one changes the person's own pointer and what it sets
/// outlives sTools.
@MainActor
public protocol CursorSwapping: AnyObject {
    /// Whether this macOS has every call the swap needs. Without them nothing is changed.
    var isSupported: Bool { get }
    /// What macOS has registered under `name` now, or nil when it has nothing there.
    func registered(_ name: String) -> RegisteredCursor?
    /// Registers `cursor` under each of `names`, then has macOS draw it.
    func apply(_ cursor: CursorImage, names: [String])
    /// Puts macOS's own cursors back, then `originals` over them, then has macOS draw the arrow.
    func restore(_ originals: [RegisteredCursor])
}

/// The real swapper, for the app's own wiring only.
@MainActor
public func makeLiveSwapper() -> any CursorSwapping {
    LiveCursorSwapper()
}
