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

    public init(
        id: UInt32,
        name: String,
        frame: CGRect,
        bounds: CGRect,
        backingScale: CGFloat,
        pixelSize: CGSize,
        isMain: Bool
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.bounds = bounds
        self.backingScale = backingScale
        self.pixelSize = pixelSize
        self.isMain = isMain
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
            isMain: displayID == CGMainDisplayID()
        )
    }
}
