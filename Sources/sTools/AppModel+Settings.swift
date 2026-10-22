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
        controller(for: .windowBackdrop, as: BackdropController.self)?.resetToDefault()
        controller(for: .nbbOverlay, as: NBBOverlayController.self)?.resetToDefault()
        timerOverlay?.resetToDefault()
        keyRebinder?.resetToDefault()
        controller(for: .screenRecording, as: ScreenRecordingController.self)?.resetToDefault()
    }

    // MARK: - Help ▸ Copy Diagnostics (spec 6.2)

    func copyDiagnostics(to clipboard: any ClipboardWriting = PasteboardClipboard()) {
        let enabledTools = ToolID.allCases.filter { isOn($0) }.map(\.title)
        let report = DiagnosticsReport(
            system: .current(),
            displays: displays.displays,
            permissions: [.accessibility: permissions.status(.accessibility)],
            karabiner: keyRebinder?.diagnosticsSummary ?? "Not available",
            ninjabrain: ninjabrainSummary,
            minecraft: minecraft.active != nil ? "Detected: \(minecraft.active?.version ?? "unknown version")" : "Not running",
            enabledTools: enabledTools,
            settingsFiles: SettingsFileInfo.list(in: settings.directory),
            logReader: OSLogLineReader())
        report.copy(to: clipboard)
    }

    private var ninjabrainSummary: String {
        guard let nbb = controller(for: .nbbOverlay, as: NBBOverlayController.self) else { return "Not available" }
        guard nbb.isEnabled else { return "Off" }
        guard nbb.isReachable else { return "Not reachable at localhost:52533" }
        return "Connected" + (nbb.nbbVersion.map { ", version \($0)" } ?? "")
    }
}
