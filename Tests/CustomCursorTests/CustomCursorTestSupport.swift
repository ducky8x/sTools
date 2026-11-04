import CoreGraphics
import Foundation
import ImageIO
@testable import CustomCursor
@testable import STPlatform

/// Stands in for the window server: it keeps what's registered by name and records every apply, restore and read, and
/// never touches the real pointer.
@MainActor
final class FakeCursorSwapper: CursorSwapping {
    enum Call: Equatable {
        case read(String)
        case apply
        case restore
    }

    var isSupported: Bool
    /// What's registered now, by name: macOS 27.2's two arrow names until something is applied.
    private(set) var current: [String: RegisteredCursor] = FakeCursorSwapper.systemArrows
    private(set) var calls: [Call] = []
    private(set) var applied: [CursorImage] = []
    private(set) var restored: [[RegisteredCursor]] = []
    /// Run during an apply or a restore, so a test can look at the marker at that moment.
    var duringApply: (() -> Void)?
    var duringRestore: (() -> Void)?

    static let systemArrows: [String: RegisteredCursor] = Dictionary(uniqueKeysWithValues: CursorNames.arrow.prefix(2).map {
        ($0, RegisteredCursor.systemArrow(name: $0))
    })

    init(isSupported: Bool = true) {
        self.isSupported = isSupported
    }

    var applyCount: Int { applied.count }
    var restoreCount: Int { restored.count }

    func registered(_ name: String) -> RegisteredCursor? {
        calls.append(.read(name))
        return current[name]
    }

    func apply(_ cursor: CursorImage, names: [String]) {
        calls.append(.apply)
        applied.append(cursor)
        duringApply?()
        for name in names {
            current[name] = RegisteredCursor(name: name, size: cursor.size, hotSpot: cursor.hotSpot, frameCount: 1, frameDuration: 0,
                                             images: cursor.images)
        }
    }

    func restore(_ originals: [RegisteredCursor]) {
        calls.append(.restore)
        restored.append(originals)
        duringRestore?()
        current = Self.systemArrows
        for original in originals { current[original.name] = original }
    }
}

@MainActor
func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-cursor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A display that exists only in tests.
let testDisplay = DisplayInfo(
    id: 1, name: "Display 1", frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -9000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: true)

/// Minecraft's window, in front or behind, at `x`.
func minecraft(frontmost: Bool, x: CGFloat = 0) -> MinecraftInstance {
    let window = MinecraftWindow(windowNumber: 42, processID: 4242, title: "Minecraft* 1.16.1", frame: CGRect(x: x, y: 0, width: 800, height: 600))
    return MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1), isFrontmost: frontmost, displayID: testDisplay.id)
}

struct GrantingProber: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// Services over a temporary folder and a Minecraft the test moves itself.
@MainActor
func makeServices(directory: URL, source: StaticMinecraftWindowSource = StaticMinecraftWindowSource()) -> ToolServices {
    ToolServices(settings: SettingsStore(directory: directory, debounce: .milliseconds(1)),
                 displays: DisplayDirectory(screenProvider: { [testDisplay] }),
                 minecraft: MinecraftLocator(source: source), permissions: PermissionCenter(prober: GrantingProber()))
}

/// Waits, bounded by awake time, for `condition`, letting the main actor run between looks.
@MainActor
func waitUntil(timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Writes a `width` × `height` PNG to `url`.
func writePNG(width: Int, height: Int, to url: URL) {
    let image = makeImage(width: width, height: height)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
