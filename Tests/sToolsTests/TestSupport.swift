import Backdrop
import CoreGraphics
import Crosshair
import Foundation
import NBBOverlay
import STDesign
@testable import STPlatform
import Synchronization
import Testing
@testable import sTools

/// A permission prober whose answers the test sets; requests never show a system prompt.
final class FakeProber: PermissionProbing {
    private let statuses = Mutex<[Permission: PermissionStatus]>([:])
    private let requests = Mutex<[Permission]>([])

    init(accessibility: PermissionStatus = .granted) {
        statuses.withLock { $0[.accessibility] = accessibility }
    }

    var requested: [Permission] { requests.withLock { $0 } }

    func set(_ permission: Permission, _ status: PermissionStatus) {
        statuses.withLock { $0[permission] = status }
    }

    func status(for permission: Permission) -> PermissionStatus {
        statuses.withLock { $0[permission] ?? .denied }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        requests.withLock { $0.append(permission) }
        return status(for: permission)
    }
}

/// Never actually registers with the system; tests drive presses by calling `onPress` directly.
@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var registered: [UUID: HotkeyCombo] = [:]

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        registered[id] = combo
    }

    func unregister(id: UUID) {
        registered[id] = nil
    }
}

/// Records each hotkey confirmation instead of showing a panel.
@MainActor
final class FakeHotkeyHUD: HotkeyConfirmationPresenting {
    private(set) var presented: [(line: String, sealed: Bool, displayID: UInt32)] = []
    var lines: [String] { presented.map(\.line) }

    func present(_ line: String, sealed: Bool, on display: DisplayInfo) {
        presented.append((line, sealed, display.id))
    }
}

/// Captures what was copied instead of touching the real system pasteboard.
@MainActor
final class FakeClipboard: ClipboardWriting {
    private(set) var copiedText: String?
    func copy(_ text: String) { copiedText = text }
}

/// Records every `setEnabled` call.
@MainActor
final class FakeController: ToolController {
    private(set) var isEnabled = false
    private(set) var calls: [Bool] = []

    func setEnabled(_ enabled: Bool) {
        calls.append(enabled)
        isEnabled = enabled
    }
}

/// URLs the permission center asked the system to open.
@MainActor
final class OpenedURLs {
    var urls: [URL] = []
}

/// The harness's one display, its main: display 1, where `fakeInstance()` puts Minecraft, but far outside every
/// real display, so a real controller switched on draws its panel where nothing shows on screen.
let harnessDisplay = DisplayInfo(
    id: 1, name: "Off screen", frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -9000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: true)

/// An `AppModel` wired to a temporary settings directory, fake permissions, a static Minecraft source and
/// `harnessDisplay`. The directory is removed when the harness goes away.
@MainActor
final class Harness {
    let model: AppModel
    let prober: FakeProber
    let source: StaticMinecraftWindowSource
    let store: SettingsStore
    let directory: URL
    let controllers: [ToolID: FakeController]
    let opened = OpenedURLs()
    let hotkeyRegistrar: any HotkeyRegistering
    let hotkeyHUD = FakeHotkeyHUD()

    /// `prologueCompleted: false` launches as a first launch, with the introduction showing.
    init(accessibility: PermissionStatus = .granted, instances: [MinecraftInstance] = [],
         theme: STTheme = STTheme(), usesRealControllers: Bool = false, hotkeyRegistrar: any HotkeyRegistering = FakeHotkeyRegistrar(),
         prologueCompleted: Bool = true) {
        self.hotkeyRegistrar = hotkeyRegistrar
        directory = FileManager.default.temporaryDirectory.appending(path: "sTools-app-\(UUID().uuidString)")
        prober = FakeProber(accessibility: accessibility)
        source = StaticMinecraftWindowSource(instances: instances)
        store = SettingsStore(directory: directory, debounce: .milliseconds(10))
        if prologueCompleted { store.save(AppState(prologueCompleted: true)) }
        var fakes: [ToolID: FakeController] = [:]
        if !usesRealControllers {
            for tool in ToolID.allCases where tool.hasSwitch { fakes[tool] = FakeController() }
        }
        controllers = fakes
        let opened = opened
        let permissions = PermissionCenter(prober: prober, openURL: { opened.urls.append($0) })
        let services = ToolServices(settings: store, displays: DisplayDirectory(screenProvider: { [harnessDisplay] }),
                                    minecraft: MinecraftLocator(source: source), permissions: permissions)
        let all: [ToolID: any ToolController] = usesRealControllers
            ? [.nbbOverlay: NBBOverlayController(services: services),
               .windowBackdrop: BackdropController(services: services),
               .crosshair: CrosshairController(services: services)]
            : fakes.mapValues { $0 as any ToolController }
        model = AppModel(services: services, theme: theme, sound: .silent, controllers: all, hotkeyRegistrar: hotkeyRegistrar,
                         hotkeyHUD: hotkeyHUD, loginItem: FakeLoginItem())
        model.pingNinjabrainBot = { false }
        model.evaluateKarabiner = { .notInstalled }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// One Minecraft window on display 1.
func fakeInstance(pid: Int32 = 100, version: String = "1.16.1", launched: TimeInterval = 1, displayID: UInt32? = 1) -> MinecraftInstance {
    let window = MinecraftWindow(windowNumber: UInt32(pid), processID: pid, title: "Minecraft* \(version)",
                                 frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    return MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: launched), displayID: displayID)
}

/// Waits (bounded) for `condition`, yielding to the main actor between checks.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
