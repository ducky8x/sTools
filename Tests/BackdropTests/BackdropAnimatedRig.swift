import AppKit
import CoreGraphics
import Foundation
import STDesign
import Testing
@testable import Backdrop
@testable import STPlatform

/// The tests' displays, far outside every real display, so a panel placed on one never shows on screen. Nothing here
/// orders a panel in: `showsPanels` is off.
let displayOne = DisplayInfo(
    id: 1, name: "Off screen", frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -9000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: true)
let displayTwo = DisplayInfo(
    id: 2, name: "Also off screen", frame: CGRect(x: -12000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -12000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: false)

struct SilentProber: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// What the fake environment saw and what it answers.
@MainActor
final class PlayerLog {
    var players: [FakePlayer] = []
    var urls: [URL] = []
    /// What the window server says about every panel.
    var panelsCanBeSeen = true
}

/// A controller on the off-screen display with Minecraft open on it, a clock moved by hand, notification centers of its
/// own and players that only record what they're told.
@MainActor
final class AnimatedRig {
    let folder: TempFolder
    let log = PlayerLog()
    let clock = FakeFrameClock()
    let workspace = NotificationCenter()
    let windows = NotificationCenter()
    let source: StaticMinecraftWindowSource
    let services: ToolServices
    let controller: BackdropController
    var imagesDirectory: URL { folder.file("Images") }

    init(folder: TempFolder = TempFolder(), showsPanels: Bool = false, minecraftWindowNumber: UInt32 = 42, theme: STTheme? = nil, displays: [DisplayInfo] = [displayOne], minecraftOpen: Bool = true,
         makePlayer: (@MainActor (URL, any BackdropFrameClock) -> any BackdropPlayer)? = nil) {
        self.folder = folder
        let window = MinecraftWindow(windowNumber: minecraftWindowNumber, processID: 4242, title: "Minecraft* 1.16.1", frame: displayOne.frame)
        let instance = MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1), isFrontmost: true, displayID: displayOne.id)
        source = StaticMinecraftWindowSource(instances: minecraftOpen ? [instance] : [])
        let locator = MinecraftLocator(source: source)
        services = ToolServices(
            settings: SettingsStore(directory: folder.url), displays: DisplayDirectory(screenProvider: { displays }),
            minecraft: locator, permissions: PermissionCenter(prober: SilentProber()))
        locator.refresh()
        let log = log
        let environment = BackdropPlaybackEnvironment(
            makePlayer: makePlayer ?? { url, _ in
                let player = FakePlayer(naturalSize: CGSize(width: 1920, height: 1080))
                log.players.append(player)
                log.urls.append(url)
                return player
            },
            clock: clock, windowCanBeSeen: { _ in log.panelsCanBeSeen },
            workspaceNotifications: workspace, windowNotifications: windows)
        controller = BackdropController(services: services, imagesDirectory: folder.file("Images"), showsPanels: showsPanels, theme: theme, playback: environment)
    }

    var player: FakePlayer { log.players.last! }

    /// Makes the main fill an animated one for `name`.
    func animate(_ name: String = "Images/loop.mp4", mode: BackdropSettings.ImageContentMode = .fill) {
        var fill = controller.settings.fill
        fill.kind = .animated
        fill.animationName = name
        fill.imageContentMode = mode
        controller.settings.fill = fill
    }

    /// Changes Minecraft's window and lets the controller see it.
    func minecraft(minimized: Bool = false, fullScreen: Bool = false, frontmost: Bool = true) {
        var instance = source.instances[0]
        instance.window.isMinimized = minimized
        instance.window.isFullScreen = fullScreen
        instance.isFrontmost = frontmost
        source.instances = [instance]
        services.minecraft.refresh()
        controller.reconcile()
    }

    func closeMinecraft() {
        source.instances = []
        services.minecraft.refresh()
        controller.reconcile()
    }

    func screensSleep() { workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil) }
    func screensWake() { workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil) }

    /// The window server reports a change in what can be seen of `displayID`'s panel.
    func panelVisibilityChanges(canBeSeen: Bool, on displayID: UInt32 = displayOne.id) {
        log.panelsCanBeSeen = canBeSeen
        windows.post(name: NSWindow.didChangeOcclusionStateNotification, object: controller.existingPanel(for: displayID))
    }
}

