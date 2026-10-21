import AppKit
import CoreGraphics

/// One connected display.
public struct DisplayInfo: Identifiable, Equatable, Sendable {
    /// The `CGDirectDisplayID`.
    public let id: UInt32
    public let name: String
    /// AppKit global coordinates (bottom-left origin), equal to `NSScreen.frame`.
    public let frame: CGRect
    /// Core Graphics global coordinates (top-left origin), equal to `CGDisplayBounds`.
    public let bounds: CGRect
    public let backingScale: CGFloat
    /// Native pixels of the display's current mode.
    public let pixelSize: CGSize
    public let isMain: Bool
    /// The panel's own pixels: the mode macOS marks as native. Nil when no mode carries the mark. A scaled
    /// resolution's current mode reports its backing size (2294 x 1490 on a 3024 x 1964 panel), so this is the
    /// only way to tell it's resampled.
    public let nativePixelSize: CGSize?

    public init(
        id: UInt32,
        name: String,
        frame: CGRect,
        bounds: CGRect,
        backingScale: CGFloat,
        pixelSize: CGSize,
        isMain: Bool,
        nativePixelSize: CGSize? = nil
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.bounds = bounds
        self.backingScale = backingScale
        self.pixelSize = pixelSize
        self.isMain = isMain
        self.nativePixelSize = nativePixelSize
    }

    /// Whether macOS draws this display at a resolution other than the panel's own ("More Space" or "Larger
    /// Text") and resamples it, so nothing on it can be pixel-exact. False when the panel's size isn't known.
    public var isScaledMode: Bool {
        guard let nativePixelSize else { return false }
        return abs(nativePixelSize.width - frame.width * backingScale) > 0.5
            || abs(nativePixelSize.height - frame.height * backingScale) > 0.5
    }

    /// The size of the mode macOS marks as native (IOKit's `kDisplayModeNativeFlag`), looking at every mode
    /// including the duplicate low-resolution ones.
    static func nativePixelSize(of displayID: CGDirectDisplayID) -> CGSize? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }
        let nativeFlag: UInt32 = 0x0200_0000
        return modes.first { $0.ioFlags & nativeFlag != 0 }.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
    }

    /// Returns nil when the screen carries no display ID.
    @MainActor
    public init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = number.uint32Value
        let mode = CGDisplayCopyDisplayMode(displayID)
        let pixelSize =
            mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
            ?? CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor)
        self.init(
            id: displayID,
            name: screen.localizedName,
            frame: screen.frame,
            bounds: CGDisplayBounds(displayID),
            backingScale: screen.backingScaleFactor,
            pixelSize: pixelSize,
            isMain: displayID == CGMainDisplayID(),
            nativePixelSize: Self.nativePixelSize(of: displayID)
        )
    }
}
