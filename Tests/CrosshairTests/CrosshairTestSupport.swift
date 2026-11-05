import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
@testable import Crosshair
@testable import STPlatform

/// A display that exists only in tests. Nothing is ever drawn on it, so it may overlap the real screens.
func syntheticDisplay(id: UInt32 = 1, frame: CGRect, scale: CGFloat, isMain: Bool = true) -> DisplayInfo {
    DisplayInfo(
        id: id, name: "Display \(id)", frame: frame, bounds: frame, backingScale: scale,
        pixelSize: CGSize(width: frame.width * scale, height: frame.height * scale), isMain: isMain)
}

/// One plain 1920 x 1080 display, so no test depends on the real screens.
let fullHDDisplay = syntheticDisplay(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)

@MainActor
func makeServices(tempDirectory: URL, instances: [MinecraftInstance] = [], displays: [DisplayInfo] = [fullHDDisplay]) -> ToolServices {
    makeServices(tempDirectory: tempDirectory, source: StaticMinecraftWindowSource(instances: instances), displays: displays)
}

@MainActor
func makeServices(tempDirectory: URL, source: StaticMinecraftWindowSource, displays: [DisplayInfo] = [fullHDDisplay]) -> ToolServices {
    let settings = SettingsStore(directory: tempDirectory)
    let displays = DisplayDirectory(screenProvider: { displays })
    let minecraft = MinecraftLocator(source: source)
    let permissions = PermissionCenter(prober: NeverPromptingProber())
    return ToolServices(settings: settings, displays: displays, minecraft: minecraft, permissions: permissions)
}

/// A controller whose panel is never ordered onto a screen, with its images in the test's temp directory.
@MainActor
func makeController(_ services: ToolServices) -> CrosshairController {
    CrosshairController(services: services, imagesDirectory: services.settings.directory.appending(path: "Images"), showsPanel: false)
}

struct NeverPromptingProber: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

@MainActor
func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-crosshair-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Rendering

/// One pixel: premultiplied red, green, blue and alpha.
struct RGBA: Equatable, CustomStringConvertible {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
    static let white = RGBA(red: 255, green: 255, blue: 255, alpha: 255)

    var description: String { "(\(red), \(green), \(blue), \(alpha))" }

    /// Whether every channel is within `tolerance` of `other`'s.
    func matches(_ other: RGBA, tolerance: Int = 0) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance && abs(Int(alpha) - Int(other.alpha)) <= tolerance
    }

    /// This pixel laid over `background`, the way a translucent pixel shows over what's behind it.
    func over(_ background: RGBA) -> RGBA {
        func blend(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            UInt8(Int(top) + (Int(bottom) * (255 - Int(alpha)) + 127) / 255)
        }
        return RGBA(
            red: blend(red, background.red), green: blend(green, background.green),
            blue: blend(blue, background.blue), alpha: blend(alpha, background.alpha))
    }
}

/// A bitmap as premultiplied RGBA bytes in device RGB, top row first.
struct RGBABitmap {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    /// A fully transparent bitmap.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// `image`'s pixels, read back without resampling or color matching.
    init(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
        let (width, height) = (self.width, self.height)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The pixel at `(x, y)`, top-left origin; clear outside the bitmap.
    subscript(x: Int, y: Int) -> RGBA {
        guard x >= 0, y >= 0, x < width, y < height else { return .clear }
        let index = (y * width + x) * 4
        return RGBA(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2], alpha: bytes[index + 3])
    }

    /// The bounds of the pixels that aren't fully transparent.
    var drawnBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<height {
            for x in 0..<width where self[x, y].alpha > 0 {
                bounds = (min(bounds?.minX ?? x, x), min(bounds?.minY ?? y, y), max(bounds?.maxX ?? x, x), max(bounds?.maxY ?? y, y))
            }
        }
        return bounds
    }
}

/// Draws `view` into a new bitmap at `scale` backing pixels per point, as a display of that scale shows
/// it, without putting any window on screen.
@MainActor
func capture(_ view: NSView, scale: CGFloat) -> RGBABitmap {
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    return RGBABitmap(rep.cgImage!)
}

/// The real overlay: the controller's own panel, given `settings` and switched on with `displays`, its
/// content drawn at the scale of the display it's placed on. The panel is never ordered in.
@MainActor
func renderOverlay(_ settings: CrosshairSettings, displays: [DisplayInfo], customImage: URL? = nil) -> (frame: CGRect, bitmap: RGBABitmap, previewImage: CGImage?) {
    _ = NSApplication.shared
    let controller = makeController(makeServices(tempDirectory: tempDirectory(), displays: displays))
    if let customImage { controller.importImage(from: customImage) }
    var settings = settings
    settings.imageName = controller.settings.imageName
    controller.settings = settings
    controller.setEnabled(true)
    defer { controller.setEnabled(false) }
    let display = settings.displayChoice == .specific
        ? displays.first { $0.id == settings.specificDisplayID }!
        : displays.first(where: \.isMain)!
    let frame = controller.panel.frame
    return (frame, capture(controller.panel.contentView!, scale: display.backingScale), controller.previewImage)
}

/// The Crosshair page's preview, hosted in a window that's never ordered in, as a display of `scale`
/// shows it.
@MainActor
func renderPreview(_ settings: CrosshairSettings, customImage: CGImage? = nil, scale: CGFloat) -> RGBABitmap {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: CrosshairPreview(settings: settings, customImage: customImage).environment(\.displayScale, scale))
    host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    return capture(host, scale: scale)
}

/// Writes a small PNG with distinct colors and translucent pixels, for an image crosshair.
func writeTestImage(to url: URL) {
    let (width, height) = (9, 7)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let alpha = 80 + (x + y) * 12
            bytes[index] = UInt8(alpha * x / (width - 1))
            bytes[index + 1] = UInt8(alpha * y / (height - 1))
            bytes[index + 2] = UInt8(alpha / 2)
            bytes[index + 3] = UInt8(alpha)
        }
    }
    let image = bytes.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// MARK: - The pointer

/// Stands in for the window server's pointer calls: it records each apply and restore and never touches the real pointer.
@MainActor
final class FakeCursorSwapper: CursorSwapping {
    var isSupported: Bool
    private(set) var applied: [CursorImage] = []
    private(set) var restoreCount = 0
    /// Whether the fake's pointer is what macOS would draw now.
    private(set) var showsTheCrosshair = false

    init(isSupported: Bool = true) {
        self.isSupported = isSupported
    }

    var applyCount: Int { applied.count }
    /// Every apply and restore, in order.
    private(set) var calls: [String] = []

    func registered(_ name: String) -> RegisteredCursor? { nil }

    func apply(_ cursor: CursorImage, names: [String]) {
        applied.append(cursor)
        calls.append("apply")
        showsTheCrosshair = true
    }

    func restore(_ originals: [RegisteredCursor]) {
        restoreCount += 1
        calls.append("restore")
        showsTheCrosshair = false
    }
}

/// Stands in for the pointer watch: the test says whether the pointer shows, and a change while it watches is reported
/// at once. Nothing reads the real pointer.
@MainActor
final class FakePointerWatch: PointerVisibilityWatching {
    var isSupported: Bool
    private(set) var isWatching = false
    private(set) var startCount = 0
    private var onChange: (@MainActor @Sendable (Bool) -> Void)?

    /// Whether the pointer shows: false in the game, true in a menu.
    var pointerShows: Bool {
        didSet { if isWatching, pointerShows != oldValue { onChange?(pointerShows) } }
    }

    init(pointerShows: Bool = false, isSupported: Bool = true) {
        self.pointerShows = pointerShows
        self.isSupported = isSupported
    }

    func start(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        stop()
        guard isSupported else { return }
        isWatching = true
        startCount += 1
        self.onChange = onChange
        onChange(pointerShows)
    }

    func stop() {
        isWatching = false
        onChange = nil
    }
}

/// A Crosshair whose panel is never ordered in, with a pointer swap over `swapper` and `watch`, in a folder of its own,
/// and a Minecraft the test moves.
@MainActor
struct MenuRig {
    let source: StaticMinecraftWindowSource
    let services: ToolServices
    let swapper: FakeCursorSwapper
    let watch: FakePointerWatch
    let controller: CrosshairController

    init(minecraftInFront: Bool = true, display: DisplayInfo = fullHDDisplay, swapper: FakeCursorSwapper = FakeCursorSwapper(),
         watch: FakePointerWatch = FakePointerWatch(), withPointer: Bool = true) {
        source = StaticMinecraftWindowSource(instances: [menuRigMinecraft(frontmost: minecraftInFront, display: display)])
        let directory = tempDirectory()
        services = makeServices(tempDirectory: directory, source: source, displays: [display])
        services.minecraft.start()
        self.swapper = swapper
        self.watch = watch
        controller = CrosshairController(
            services: services, imagesDirectory: directory.appending(path: "Images"), showsPanel: false,
            pointer: withPointer ? PointerSwap(swapper: swapper, supportDirectory: directory) : nil, pointerWatch: watch)
    }

    /// Minecraft in front or behind, on the rig's display.
    func setMinecraft(inFront: Bool, display: DisplayInfo = fullHDDisplay) {
        source.instances = [menuRigMinecraft(frontmost: inFront, display: display)]
        services.minecraft.refresh()
    }

    /// Minecraft quits.
    func quitMinecraft() {
        source.instances = []
        services.minecraft.refresh()
    }

    func stop() {
        controller.setEnabled(false)
        services.minecraft.stop()
    }
}

func menuRigMinecraft(frontmost: Bool, display: DisplayInfo = fullHDDisplay) -> MinecraftInstance {
    let window = MinecraftWindow(windowNumber: 42, processID: 4242, title: "Minecraft* 1.16.1", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    return MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1), isFrontmost: frontmost, displayID: display.id)
}

/// Waits, without blocking the main actor, until `condition` holds or 20 s of awake time pass.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: .seconds(20))
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
