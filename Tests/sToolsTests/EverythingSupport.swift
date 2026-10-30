import AppKit
import Foundation
@testable import Backdrop
@testable import Crosshair
@testable import NBBOverlay
@testable import ScreenRecording
import STDesign
@testable import STPlatform
import Testing
@testable import TimerOverlay
@testable import sTools

// The QA matrix's "each tool alone and all together", "one and two displays" and "windowed and full-screen" cells
// (spec 9.2) at the app's level: the app model over every real controller (Crosshair, Timer Overlay, NBB Overlay,
// Screen Recording, Window Backdrop), on fakes for everything outside the process. Their windows are real, but on
// displays far outside every real one, so nothing ever shows on a screen. Nothing asks for a permission, plays a sound,
// captures anything, opens a port or reads a Ninjabrain Bot or a Minecraft.

/// Where a display of these tests sits: far from every real screen, and from the displays other suites use (which
/// start at -9000), so a panel found there is this test's.
enum QADisplays {
    private static let originX: CGFloat = -30_000
    private static let originY: CGFloat = -30_000
    /// The height the primary display would have (the Core Graphics origin is at the top of it).
    private static let primaryHeight: CGFloat = 1080

    /// Display `id` (1 is the main one), placed side by side from the first slot.
    static func display(id: UInt32, size: CGSize = CGSize(width: 1920, height: 1080), scale: CGFloat = 1,
                        nativePixelSize: CGSize? = nil) -> DisplayInfo {
        let frame = CGRect(x: originX + CGFloat(id - 1) * 2_400, y: originY, width: size.width, height: size.height)
        let bounds = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: size.width, height: size.height)
        return DisplayInfo(id: id, name: "QA display \(id)", frame: frame, bounds: bounds, backingScale: scale,
                           pixelSize: CGSize(width: size.width * scale, height: size.height * scale), isMain: id == 1,
                           nativePixelSize: nativePixelSize)
    }

    /// A Minecraft window on `display`, 1600 x 900 points inside it (Core Graphics coordinates).
    static func minecraft(on display: DisplayInfo, pid: Int32 = 4242, title: String = "Minecraft* 1.16.1",
                          fullScreen: Bool = false, frontmost: Bool = true, launched: TimeInterval = 1) -> MinecraftInstance {
        let frame = fullScreen ? display.bounds : display.bounds.insetBy(dx: 160, dy: 90)
        let window = MinecraftWindow(windowNumber: UInt32(pid), processID: pid, title: title, frame: frame, isFullScreen: fullScreen)
        return MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: launched), isFrontmost: frontmost,
                                 displayID: display.id)
    }
}

/// The displays of a test, which the test changes the way plugging a monitor in or out does.
@MainActor
final class DisplayBox {
    var displays: [DisplayInfo]
    init(_ displays: [DisplayInfo]) { self.displays = displays }
}

/// Ninjabrain Bot's API without Ninjabrain Bot: every stream stays open, the stronghold stream sends one result as soon as
/// it opens, and the version check answers. No port is opened and nothing on the Mac is read.
struct ScriptedNBBSource: NBBEventSource {
    static let result = #"""
    {"resultType":"TRIANGULATION",
     "predictions":[{"chunkX":12,"chunkZ":-34,"certainty":0.87,"overworldDistance":512.3}],
     "eyeThrows":[{"xInOverworld":100.0,"zInOverworld":-200.0,"angle":45.0,"angleWithoutCorrection":44.5,
                   "correction":0.5,"correctionIncrements":2,"error":0.01,"type":"NORMAL"}],
     "playerPosition":{"xInOverworld":1.0,"zInOverworld":2.0,"horizontalAngle":90.0,"isInOverworld":true,"isInNether":false}}
    """#.replacingOccurrences(of: "\n", with: "")

    func connect(to url: URL) async throws -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            if url.path.hasSuffix("version") {
                continuation.yield(Array(#"{"version":"1.5.2"}"#.utf8))
                continuation.finish()
            } else if url.path.hasSuffix("stronghold/events") {
                continuation.yield(Array("data: \(Self.result)\n\n".utf8))
            }
        }
    }
}

/// A Save/Delete question nobody sees.
@MainActor
final class NoQuestion: RecordingDecisionPresenting {
    func present(for controller: ScreenRecordingController) {}
    func dismiss() {}
}

/// No capture at all: a recording would be a blank canvas.
@MainActor
final class NothingToCapture: CaptureFactory {
    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func video(for source: VideoSource, canvas: ScreenRecording.PixelSize, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func audio(for source: AudioSource) -> (any AudioCapture)? { nil }
    func minecraftAudio(processID: Int32) -> (any AudioCapture)? { nil }
}

/// The app with all five switchable tools real, over a display list the test changes.
@MainActor
final class EverythingHarness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-qa-everything-\(UUID().uuidString)", directoryHint: .isDirectory)
    let displayBox: DisplayBox
    let source: StaticMinecraftWindowSource
    let prober = FakeProber(accessibility: .granted)
    let theme: STTheme
    let registrar = FakeHotkeyRegistrar()
    let hud = FakeHotkeyHUD()
    let timerClock = FakeTimerClock()
    let timerScheduler = FakeTimerScheduler()
    let presenter: TimerOverlayPresenter
    let timerAnnouncer = FakeTimerAnnouncer()
    let crosshair: CrosshairController
    let nbb: NBBOverlayController
    let backdrop: BackdropController
    let timer: TimerOverlayController
    let recording: ScreenRecordingController
    let model: AppModel

    /// - Parameter reducedMotion: Reduce animations, set the way its switch sets it (the app loads the saved appearance
    ///   over the theme it is given, so a theme made reduced would be made full again).
    init(displays: [DisplayInfo] = [QADisplays.display(id: 1)], instances: [MinecraftInstance]? = nil,
         reducedMotion: Bool = true, theme: STTheme = STTheme()) {
        self.theme = theme
        displayBox = DisplayBox(displays)
        source = StaticMinecraftWindowSource(instances: instances ?? [QADisplays.minecraft(on: displays[0])])
        let store = SettingsStore(directory: directory, debounce: .milliseconds(10))
        store.save(AppState(prologueCompleted: true))
        store.save(HotkeySettings())
        prober.set(.screenRecording, .granted)
        let box = displayBox
        let services = ToolServices(
            settings: store, displays: DisplayDirectory(screenProvider: { box.displays }),
            minecraft: MinecraftLocator(source: source, coalescing: .milliseconds(5)),
            permissions: PermissionCenter(prober: prober, openURL: { _ in }))
        services.minecraft.refresh()
        timerScheduler.clock = timerClock
        presenter = TimerOverlayPresenter(theme: theme, scheduler: timerScheduler, clock: timerClock)
        let images = directory.appending(path: "Images", directoryHint: .isDirectory)
        crosshair = CrosshairController(services: services, imagesDirectory: images, showsPanel: true)
        nbb = NBBOverlayController(
            services: services, connection: NBBConnection(source: ScriptedNBBSource()),
            copies: NBBCopiesMonitor(scanner: NoNBBCopiesScanner()), theme: theme)
        backdrop = BackdropController(services: services, imagesDirectory: images, showsPanels: true, theme: theme)
        timer = TimerOverlayController(
            services: services, theme: theme, clock: timerClock, scheduler: timerScheduler, activity: FakeTimerActivity(),
            wakeWatcher: FakeTimerWakeWatcher(), presenter: presenter, guides: FakeRuleGuides(), alarm: FakeAlarm(),
            announcer: timerAnnouncer, inProcessAudio: InProcessAudio())
        recording = ScreenRecordingController(
            services: services, makeFactory: { _ in NothingToCapture() }, loadAvailable: { _ in AvailableSources() },
            inProcessAudio: InProcessAudio(), decisionPresenter: NoQuestion())
        recording.options.folderPath = directory.appending(path: "Movies", directoryHint: .isDirectory).path
        model = AppModel(
            services: services, theme: theme, sound: .silent,
            controllers: [.crosshair: crosshair, .timerOverlay: timer, .nbbOverlay: nbb, .screenRecording: recording, .windowBackdrop: backdrop],
            hotkeyRegistrar: registrar, hotkeyHUD: hud, loginItem: FakeLoginItem())
        model.pingNinjabrainBot = { false }
        model.evaluateKarabiner = { .notInstalled }
        model.appearanceBinding(\.reducesAnimations).wrappedValue = reducedMotion
    }

    /// Turns every tool off, as quitting does, and writes what is pending; then lets the Timer Overlay's exit finish (its
    /// scheduler is the test's, so the backstop that releases a panel whose animation never reports its end is fired by
    /// hand) and waits until no window of the test is left, so a failed test leaves nothing for the next one to find.
    func finish() async {
        await model.shutDown()
        for _ in 0..<20 where !timerScheduler.pending.isEmpty {
            for wake in timerScheduler.pending {
                wake.isCancelled = true
                wake.action()
            }
        }
        _ = await waitUntil(timeout: .seconds(10)) { self.displayBox.displays.allSatisfy { self.panels(on: $0).isEmpty } }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A display of the test, by id.
    func display(_ id: UInt32) -> DisplayInfo { displayBox.displays.first { $0.id == id }! }

    /// Tells the app the displays changed, as macOS does after a monitor comes or goes: the directory reads them again,
    /// then every observer of the notification looks at them.
    func displaysChanged() {
        model.displays.refresh()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// The overlay panels on screen now whose frame touches `display`, whichever tool made them.
    func panels(on display: DisplayInfo) -> [OverlayPanel] {
        _ = NSApplication.shared
        return NSApp.windows.compactMap { $0 as? OverlayPanel }.filter { $0.isVisible && $0.frame.intersects(display.frame) }
    }

    /// The one visible panel of `role` on `display`; fails the test when there isn't exactly one.
    func panel(_ role: OverlayPanel.Role, on display: DisplayInfo, sourceLocation: SourceLocation = #_sourceLocation) -> OverlayPanel? {
        let found = panels(on: display).filter { $0.role == role }
        #expect(found.count == 1, "\(found.count) \(role) panels on \(display.name)", sourceLocation: sourceLocation)
        return found.first
    }
}

/// The five tools that have a switch, in sidebar order.
let qaSwitchableTools: [ToolID] = [.crosshair, .timerOverlay, .nbbOverlay, .screenRecording, .windowBackdrop]
