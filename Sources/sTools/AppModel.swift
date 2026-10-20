import Backdrop
import Crosshair
import KeyRebinder
import NBBOverlay
import ScreenRecording
import Observation
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
    var appearance: AppearanceSettings
    var general: GeneralSettings
    var updates: UpdateSettings
    var toolIsOn: [ToolID: Bool] = [:]

    @ObservationIgnored let controllers: [ToolID: any ToolController]
    /// Key Rebinder has no on/off switch, so it isn't one of `controllers`.
    @ObservationIgnored let keyRebinder: KeyRebinderController?
    @ObservationIgnored let loginItem: any LoginItemControlling
    @ObservationIgnored var wasAccessibilityGranted: Bool
    @ObservationIgnored var isPollingForTools = false
    /// Set by the root view so the Dock icon can bring the window back after it was closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Home ▸ Hotkeys (spec 6.1). Built lazily so its `toolStates`/`handler` closures can capture
    /// `self` — they only run on an actual key press, well after `init` returns.
    @ObservationIgnored private let hotkeyRegistrar: any HotkeyRegistering
    @ObservationIgnored lazy var hotkeys: HotkeyCenter = HotkeyCenter(
        store: services.settings, registrar: hotkeyRegistrar,
        toolStates: { [weak self] in self?.hotkeyToolStates() ?? [:] },
        handler: { [weak self] events in self?.handleHotkeyPress(events) })
    /// Shows each press's confirmation over the game.
    @ObservationIgnored let hotkeyHUD: any HotkeyConfirmationPresenting

    /// Every tool starts off (spec 3.5). `controllers` holds the tools that exist so far.
    init(services: ToolServices, theme: STTheme, sound: STSoundPlayer, controllers: [ToolID: any ToolController],
         keyRebinder: KeyRebinderController? = nil,
         hotkeyRegistrar: any HotkeyRegistering, hotkeyHUD: any HotkeyConfirmationPresenting,
         loginItem: any LoginItemControlling) {
        self.services = services
        self.theme = theme
        self.sound = sound
        self.controllers = controllers
        self.keyRebinder = keyRebinder
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
        (controllers[.screenRecording] as? ScreenRecordingController)?.requestEnable = { [weak self] in
            guard let self else { return false }
            self.setTool(.screenRecording, on: true)
            return self.isOn(.screenRecording)
        }
    }

    /// The production wiring: real services, the live Accessibility source and the tool controllers.
    convenience init() {
        let theme = STTheme()
        let services = ToolServices(
            settings: SettingsStore(directory: SettingsStore.defaultDirectory()),
            displays: DisplayDirectory(),
            minecraft: MinecraftLocator(source: AXMinecraftSource()),
            permissions: PermissionCenter())
        self.init(services: services, theme: theme, sound: STSoundPlayer(theme: theme), controllers: [
            .nbbOverlay: NBBOverlayController(services: services),
            .windowBackdrop: BackdropController(services: services),
            .crosshair: CrosshairController(services: services),
            .screenRecording: ScreenRecordingController(services: services),
        ], keyRebinder: KeyRebinderController(services: services),
        hotkeyRegistrar: CarbonHotkeyRegistrar(), hotkeyHUD: HotkeyHUD(theme: theme), loginItem: SystemLoginItem())
        minecraft.start()
        _ = hotkeys // starts registering any saved hotkeys immediately, matching the other services.
        restoreToolsIfNeeded()
    }

    /// Closing the window mid-recording asks first (spec 5.4.4): keep recording in the background, stop and
    /// save, or cancel. SwiftUI owns the window's delegate, so this runs as the close begins and Cancel opens the
    /// window again.
    func mainWindowWillClose() {
        guard let recording = controller(for: .screenRecording, as: ScreenRecordingController.self), recording.isRecording else { return }
        let alert = NSAlert()
        alert.messageText = "Screen Recording is still recording."
        alert.informativeText = "It can keep recording with the window closed. Open sTools from the Dock to stop it later."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop and Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertSecondButtonReturn:
            Task {
                await recording.stopRecording(explanation: nil)
                if recording.phase == .deciding { await recording.save(name: nil) }
            }
        default:
            DispatchQueue.main.async { [weak self] in self?.openMainWindow?() }
        }
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
        if general.restoreToolsAtQuit {
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
