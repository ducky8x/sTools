import Backdrop
import Crosshair
import KeyRebinder
import NBBOverlay
import ScreenRecording
import STDesign
import STPlatform
import SwiftUI
import TimerOverlay

extension AppModel {
    func generalBinding<Value>(_ keyPath: WritableKeyPath<GeneralSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.general[keyPath: keyPath] },
            set: { value in
                self.general[keyPath: keyPath] = value
                self.settings.save(self.general)
            })
    }

    func updatesBinding<Value>(_ keyPath: WritableKeyPath<UpdateSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.updates[keyPath: keyPath] },
            set: { value in
                self.updates[keyPath: keyPath] = value
                self.settings.save(self.updates)
                self.updateCenter.apply(self.updates)
            })
    }

    /// Whether "Open at login" can actually be switched on right now, and why if not.
    var loginItemState: LoginItemState { loginItem.state }

    func setOpensAtLogin(_ enabled: Bool) {
        try? loginItem.setEnabled(enabled)
    }

    // MARK: - Data (spec 6.2)

    /// Every `SettingsDocument` this build knows how to read, by name — what `SettingsBackup` needs to
    /// decide whether an imported document is current, older (migrated on load) or from a newer sTools.
    static let knownSettingsVersions: [String: Int] = [
        AppearanceSettings.name: AppearanceSettings.version,
        GeneralSettings.name: GeneralSettings.version,
        UpdateSettings.name: UpdateSettings.version,
        AppState.name: AppState.version,
        HotkeySettings.name: HotkeySettings.version,
        HotkeyHeldModifierSettings.name: HotkeyHeldModifierSettings.version,
        CrosshairSettings.name: CrosshairSettings.version,
        BackdropSettings.name: BackdropSettings.version,
        NBBOverlaySettings.name: NBBOverlaySettings.version,
        KeyRebinderSettings.name: KeyRebinderSettings.version,
        RecordingOptions.name: RecordingOptions.version,
        RecordingLayout.name: RecordingLayout.version,
        TimerOverlaySettings.name: TimerOverlaySettings.version,
    ]

    @discardableResult
    func exportSettings(to url: URL) async throws -> SettingsBackup.ExportSummary {
        try await SettingsBackup(directory: settings.directory, store: settings).export(to: url)
    }

    @discardableResult
    func importSettings(from url: URL) async throws -> SettingsBackup.ImportReport {
        let report = try await SettingsBackup(directory: settings.directory, store: settings)
            .importSettings(from: url, knownVersions: Self.knownSettingsVersions)
        reloadAppearance()
        return report
    }

    /// Wipes every settings document; the caller must relaunch sTools afterward (settings objects
    /// already loaded in memory are not touched and must not be saved again).
    @discardableResult
    func resetAppSettings() async throws -> URL? {
        try await ResetService(directory: settings.directory, store: settings).reset(confirmed: true)
    }

    /// Resets every tool's own settings to default — narrower than "Reset sTools…": General,
    /// Appearance, Hotkeys and the first-launch introduction are untouched. Each tool whose controller
    /// exists handles its own save and live refresh, the same as its own "Reset to default" button.
    func resetAllToolsToDefault() {
        controller(for: .crosshair, as: CrosshairController.self)?.resetToDefault()
        timerOverlay?.resetToDefault()
        controller(for: .nbbOverlay, as: NBBOverlayController.self)?.resetToDefault()
        controller(for: .screenRecording, as: ScreenRecordingController.self)?.resetToDefault()
        controller(for: .windowBackdrop, as: BackdropController.self)?.resetToDefault()
        keyRebinder?.resetToDefault()
    }

    /// What Settings ▸ Reset All Tools… says it does, naming every tool `resetAllToolsToDefault()` resets, in sidebar
    /// order. Screen Recording's sources and layout (`recordingLayout`) and the rebinds in Karabiner-Elements are
    /// separate from those tools' settings, so they stay. Plain placeholder wording until M9.
    static var resetAllToolsMessage: String {
        let titles = ToolID.allCases.map(\.title)
        let tools = titles.dropLast().joined(separator: ", ") + " and " + (titles.last ?? "")
        return "This sets the settings of \(tools) back to their defaults. Screen Recording\u{2019}s sources and layout and "
            + "your Karabiner-Elements rebinds stay as they are. General, Appearance and Hotkeys are untouched "
            + "\u{2014} use Reset sTools below for those."
    }

    // MARK: - Help ▸ Copy Diagnostics (spec 6.2)

    /// Every permission is read fresh with the checks that never ask (`PermissionCenter.refresh()`), so the report
    /// says how each one is now and copying it brings up no prompt. The header says how hotkeys are set.
    func copyDiagnostics(to clipboard: any ClipboardWriting = PasteboardClipboard()) {
        let enabledTools = ToolID.allCases.filter { isOn($0) }.map(\.title)
        permissions.refresh()
        let report = DiagnosticsReport(
            system: .current(),
            displays: displays.displays,
            permissions: Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, permissions.status($0)) }),
            karabiner: keyRebinder?.diagnosticsSummary ?? "Not available",
            ninjabrain: ninjabrainSummary,
            minecraft: minecraft.active != nil ? "Detected: \(minecraft.active?.version ?? "unknown version")" : "Not running",
            enabledTools: enabledTools,
            settingsFiles: SettingsFileInfo.list(in: settings.directory),
            logReader: logReader,
            hotkeys: DiagnosticsHotkeys(
                isEnabled: hotkeys.isEnabled, scope: hotkeys.scope.title, keySet: HotkeyKeySet.name(of: hotkeys.keySet),
                alsoFiresWithShiftOrControl: hotkeys.alsoFiresWithShiftOrControl))
        report.copy(to: clipboard)
    }

    private var ninjabrainSummary: String {
        guard let nbb = controller(for: .nbbOverlay, as: NBBOverlayController.self) else { return "Not available" }
        guard nbb.isEnabled else { return "Off" }
        guard nbb.isReachable else { return "Not reachable at localhost:52533" }
        return "Connected" + (nbb.nbbVersion.map { ", version \($0)" } ?? "")
    }
}
