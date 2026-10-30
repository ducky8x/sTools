import Backdrop
import Crosshair
import KeyRebinder
import NBBOverlay
import Prologue
import ScreenRecording
import Observation
import TimerOverlay
import STDesign
import STPlatform
import SwiftUI

/// Owns the shared services, navigation, each tool's switch and the appearance settings.
@MainActor @Observable
final class AppModel {
    let theme: STTheme
    let sound: STSoundPlayer
    let services: ToolServices

    var settings: SettingsStore { services.settings }
    var permissions: PermissionCenter { services.permissions }
    var displays: DisplayDirectory { services.displays }
    var minecraft: MinecraftLocator { services.minecraft }

    var history = NavigationHistory()
    /// Where the next page shown should scroll to; the page clears it once it has.
    var pendingPageAnchor: PageAnchor?
    var appearance: AppearanceSettings
    var general: GeneralSettings
    var updates: UpdateSettings
    var toolIsOn: [ToolID: Bool] = [:]
    /// The first-launch introduction while it runs (spec 4); nil once finished or skipped.
    var prologue: PrologueModel?
    /// Whether the main window can be seen (open, not minimized, not covered by Minecraft or a locked screen). Pages
    /// pause their polling and previews while it's false.
    var isMainWindowVisible = true
    /// False from the moment the main window closes until it's shown again. While closed (and no introduction is
    /// running), the window holds no pages at all, so their views, layers and caches are given back.
    var isMainWindowOpen = true

    @ObservationIgnored let controllers: [ToolID: any ToolController]
    /// Key Rebinder has no on/off switch, so it isn't one of `controllers`.
    @ObservationIgnored let keyRebinder: KeyRebinderController?
    /// Settings ▸ Updates and Check for Updates… (spec 6.3); its updater is Sparkle in the app, nil or a fake in tests.
    let updateCenter: UpdateCenter
    /// Settings ▸ Updates ▸ Install from DMG…: replaces this copy with the sTools in a DMG someone downloaded.
    let dmgInstaller: DMGInstaller
    @ObservationIgnored let loginItem: any LoginItemControlling
    @ObservationIgnored var wasAccessibilityGranted: Bool
    /// Held while a tool that needs Accessibility runs, so a revoked grant turns it off (`updateToolPolling()`).
    @ObservationIgnored var toolPolling: PermissionCenter.PollingToken?
    /// Set by the root view so the Dock icon can bring the window back after it was closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Tools already on when the introduction began; its end leaves them on.
    @ObservationIgnored var toolsOnBeforePrologue: Set<ToolID> = []
    /// After Reset sTools nothing in memory may be written back before the relaunch.
    @ObservationIgnored var settingsWereReset = false
    /// The Prologue's live companion checks (spec 4.2, steps 7 and 8); tests replace them.
    @ObservationIgnored var pingNinjabrainBot: @MainActor () async -> Bool = { await NBBConnection.ping() }
    @ObservationIgnored var evaluateKarabiner: @MainActor () async -> KarabinerRequirement = {
        await KarabinerStatus(probes: .live(cli: KarabinerCLI(runner: ProcessCommandRunner(timeout: .seconds(2))))).evaluate()
    }
    @ObservationIgnored var lastKarabinerRequirement: KarabinerRequirement?
    /// What the Prologue's trials have seen so far; fresh each time the introduction starts.
    @ObservationIgnored var trials = TrialSession()
    /// Asks before the Timer trial's Start-timer key turns hotkeys on (plan decision 14); true to turn them on. Tests replace it, so no
    /// test shows an alert.
    @ObservationIgnored var confirmTurningOnHotkeys: @MainActor () -> Bool = AppModel.askToTurnOnHotkeys
    /// Follows macOS's Reduce motion into the theme. Only the real app has one; tests set the theme themselves.
    @ObservationIgnored var systemMotion: SystemMotionWatcher?

    /// Home ▸ Hotkeys (spec 6.1). Built lazily so its `toolStates`/`handler` closures can capture
    /// `self` — they only run on an actual key press, well after `init` returns.
    @ObservationIgnored private let hotkeyRegistrar: any HotkeyRegistering
    @ObservationIgnored lazy var hotkeys: HotkeyCenter = HotkeyCenter(
        store: services.settings, registrar: hotkeyRegistrar,
        toolStates: { [weak self] in self?.hotkeyToolStates() ?? [:] },
        menuShortcuts: GoCommand.menuShortcuts,
        handler: { [weak self] events in self?.handleHotkeyPress(events) })
    /// Tells Hotkeys which app is in front, for Where hotkeys work (spec 6.1). Only the real app has one; a center
    /// nobody tells acts as if sTools were in front.
    @ObservationIgnored var hotkeyFrontApp: HotkeyFrontAppWatcher?
    /// Shows each press's confirmation over the game.
    @ObservationIgnored let hotkeyHUD: any HotkeyConfirmationPresenting
    /// The sidebar marker's glide and detents (spec 3.4); tests replace it with one on a fake player and clock.
    @ObservationIgnored lazy var sidebarGlide = SidebarGlidePlayer(sound: sound) { [theme] in theme.reduceMotion }

    /// Every tool starts off (spec 3.5). `controllers` holds the tools that exist so far.
    init(services: ToolServices, theme: STTheme, sound: STSoundPlayer, controllers: [ToolID: any ToolController],
         keyRebinder: KeyRebinderController? = nil, updater: (any AppUpdating)? = nil, dmgInstaller: DMGInstaller? = nil,
         hotkeyRegistrar: any HotkeyRegistering, hotkeyHUD: any HotkeyConfirmationPresenting,
         loginItem: any LoginItemControlling) {
        self.services = services
        self.theme = theme
        self.sound = sound
        self.controllers = controllers
        self.keyRebinder = keyRebinder
        updateCenter = UpdateCenter(updater: updater, notices: AlertUpdateNoticePresenter(theme: theme))
        self.dmgInstaller = dmgInstaller ?? DMGInstaller()
        self.hotkeyRegistrar = hotkeyRegistrar
        self.hotkeyHUD = hotkeyHUD
        self.loginItem = loginItem
        let loaded = services.settings.load(AppearanceSettings.self)
        loaded.apply(to: theme)
        appearance = AppearanceSettings(theme: theme)
        general = services.settings.load(GeneralSettings.self)
        updates = services.settings.load(UpdateSettings.self)
        wasAccessibilityGranted = services.permissions.status(.accessibility) == .granted
        watchAccessibility()
        updateCenter.apply(updates)
        let recording = controllers[.screenRecording] as? ScreenRecordingController
        recording?.requestEnable = { [weak self] in
            guard let self else { return false }
            self.setTool(.screenRecording, on: true)
            return self.isOn(.screenRecording)
        }
        // Stopping a recording turns the tool off right then (spec 5.4.4), through its switch.
        recording?.requestDisable = { [weak self] in self?.setTool(.screenRecording, on: false) }
        // The key's start is confirmed over the game once the recording writes, not at the press.
        recording?.keyStartEnded = { [weak self] outcome in
            self?.confirm([HotkeyConfirmation.recordingStartEffect(outcome)])
        }
        // Start, Test, placement mode and the Start-timer key switch the tool on through its switch, so rule R10 holds.
        (controllers[.timerOverlay] as? TimerOverlayController)?.requestEnable = { [weak self] in
            guard let self else { return false }
            self.setTool(.timerOverlay, on: true)
            return self.isOn(.timerOverlay)
        }
        if PrologueModel.isNeeded(in: services.settings) { beginPrologue() }
        // The Key Rebinder shows, edits and advises on the hotkey list; without one, the list isn't built here.
        keyRebinder?.connect(hotkeys: hotkeys)
    }

    /// The production wiring: real services, the live Accessibility source and the tool controllers.
    convenience init() {
        let theme = STTheme()
        let sound = STSoundPlayer(theme: theme)
        let services = ToolServices(
            settings: SettingsStore(directory: SettingsStore.defaultDirectory()),
            displays: DisplayDirectory(),
            minecraft: MinecraftLocator(source: AXMinecraftSource()),
            permissions: PermissionCenter())
        self.init(services: services, theme: theme, sound: sound, controllers: [
            .nbbOverlay: NBBOverlayController(services: services, theme: theme),
            .windowBackdrop: BackdropController(services: services, theme: theme),
            .crosshair: CrosshairController(services: services),
            // The app's own theme, so the overlay follows Reduce animations even while the window is closed.
            .timerOverlay: TimerOverlayController(services: services, theme: theme),
            // The Save/Delete question after a stop floats in a panel of its own, so it shows over Minecraft too.
            .screenRecording: ScreenRecordingController(
                services: services, decisionPresenter: RecordingDecisionPanel(theme: theme, sound: sound)),
        ], keyRebinder: KeyRebinderController(services: services), updater: AppUpdater(),
        hotkeyRegistrar: CarbonHotkeyRegistrar(), hotkeyHUD: HotkeyHUD(theme: theme), loginItem: SystemLoginItem())
        minecraft.start()
        _ = hotkeys // starts registering any saved hotkeys immediately, matching the other services.
        // From the first moment, hotkeys follow the app in front (Where hotkeys work), on each app switch.
        let frontApp = HotkeyFrontAppWatcher(center: hotkeys, frontmost: WorkspaceFrontmostApp(), minecraft: minecraft)
        frontApp.start()
        hotkeyFrontApp = frontApp
        restoreToolsIfNeeded()
        systemMotion = SystemMotionWatcher(theme: theme)
    }

    /// Closing the window mid-recording asks first (spec 5.4.4): keep recording in the background, stop and
    /// save, or cancel. SwiftUI owns the window's delegate, so this runs as the close begins and Cancel opens the
    /// window again.
    func mainWindowWillClose() {
        guard let recording = controller(for: .screenRecording, as: ScreenRecordingController.self), recording.isRecording else { return }
        switch stillRecordingAlert().runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertSecondButtonReturn:
            // Saved under its date-and-time name without the question; the tool switches off after, as after any stop.
            Task { await recording.stopRecording(explanation: nil, savesWithoutAsking: true) }
        default:
            DispatchQueue.main.async { [weak self] in self?.openMainWindow?() }
        }
    }

    /// The question asked when the window closes mid-recording: Keep Recording, Stop and Save, or Cancel. While
    /// motion is reduced it appears without AppKit's alert animation, like the window it comes from (spec 3.4).
    func stillRecordingAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Screen Recording is still recording."
        alert.informativeText = "It can keep recording with the window closed. Open sTools from the Dock to stop it later."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop and Save")
        alert.addButton(withTitle: "Cancel")
        // Laid out now rather than just before it shows, so nothing redoes its window after this.
        alert.layout()
        alert.window.animationBehavior = WindowConfigurator.animationBehavior(reducesMotion: theme.reduceMotion)
        return alert
    }

    /// The controller registered for `tool`, if it is of type `type`.
    func controller<C: ToolController>(for tool: ToolID, as type: C.Type = C.self) -> C? {
        controllers[tool] as? C
    }

    /// Turns every tool off and writes pending settings; the app waits for this before quitting.
    /// Records which tools were on first, so `restoreToolsIfNeeded()` can bring them back next launch
    /// when Settings ▸ General ▸ Advanced "Restore tools that were on at quit" is on.
    func shutDown() async {
        let onAtQuit = ToolID.allCases.filter(isOn).map(\.rawValue)
        // A recording in progress is finished and kept under its date-and-time name; nobody is asked.
        await controller(for: .screenRecording, as: ScreenRecordingController.self)?.finishForQuit()
        if general.restoreToolsAtQuit && !settingsWereReset {
            general.toolsOnAtQuit = onAtQuit
            settings.save(general)
        }
        for tool in ToolID.allCases where isOn(tool) { setTool(tool, on: false) }
        await settings.flush()
    }

    /// Switches back on whichever tools `shutDown()` recorded, when the setting calls for it. Tools
    /// that can't switch on yet (Accessibility not granted) are silently skipped, same as a manual
    /// attempt would be.
    func restoreToolsIfNeeded() {
        guard general.restoreToolsAtQuit else { return }
        for tool in general.toolsOnAtQuit.compactMap(ToolID.init(rawValue:)) {
            setTool(tool, on: true)
        }
    }
}
