import Crosshair
import Foundation
import STPlatform
import Testing
@testable import sTools

@MainActor
@Suite("AppModel settings")
struct AppModelSettingsTests {
    @Test func generalBindingPersists() async {
        let harness = Harness(accessibility: .granted)
        harness.model.generalBinding(\.restoreToolsAtQuit).wrappedValue = true
        await harness.model.settings.flush()
        #expect(SettingsStore(directory: harness.directory).load(GeneralSettings.self).restoreToolsAtQuit)
    }

    @Test func updatesBindingPersists() async {
        let harness = Harness(accessibility: .granted)
        harness.model.updatesBinding(\.checksAutomatically).wrappedValue = false
        await harness.model.settings.flush()
        #expect(SettingsStore(directory: harness.directory).load(UpdateSettings.self).checksAutomatically == false)
    }

    @Test func settingOpensAtLoginCallsTheLoginItem() {
        let harness = Harness(accessibility: .granted)
        guard let fake = harness.model.loginItem as? FakeLoginItem else {
            Issue.record("expected FakeLoginItem")
            return
        }
        harness.model.setOpensAtLogin(true)
        #expect(fake.state == .enabled)
        #expect(harness.model.loginItemState == .enabled)
    }

    @Test func shutDownRecordsOnToolsWhenRestoreIsEnabled() async {
        let harness = Harness(accessibility: .granted, usesRealControllers: true)
        harness.model.generalBinding(\.restoreToolsAtQuit).wrappedValue = true
        harness.model.setTool(.crosshair, on: true)
        await harness.model.shutDown()
        #expect(harness.model.general.toolsOnAtQuit == [ToolID.crosshair.rawValue])
        #expect(!harness.model.isOn(.crosshair), "shutDown still turns every tool off")
    }

    @Test func shutDownDoesNotRecordWhenRestoreIsDisabled() async {
        let harness = Harness(accessibility: .granted, usesRealControllers: true)
        harness.model.setTool(.crosshair, on: true)
        await harness.model.shutDown()
        #expect(harness.model.general.toolsOnAtQuit.isEmpty)
    }

    @Test func restoreToolsIfNeededTurnsBackOnWhatWasRecorded() {
        let harness = Harness(accessibility: .granted, usesRealControllers: true)
        harness.model.generalBinding(\.restoreToolsAtQuit).wrappedValue = true
        harness.model.general.toolsOnAtQuit = [ToolID.crosshair.rawValue]
        harness.model.restoreToolsIfNeeded()
        #expect(harness.model.isOn(.crosshair))
    }

    @Test func restoreToolsIfNeededDoesNothingWhenDisabled() {
        let harness = Harness(accessibility: .granted, usesRealControllers: true)
        harness.model.general.toolsOnAtQuit = [ToolID.crosshair.rawValue]
        harness.model.restoreToolsIfNeeded()
        #expect(!harness.model.isOn(.crosshair))
    }

    @Test func exportThenImportRoundTripsASetting() async throws {
        let harness = Harness(accessibility: .granted)
        harness.model.appearanceBinding(\.soundVolume).wrappedValue = 0.42
        let file = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).stools-settings")
        defer { try? FileManager.default.removeItem(at: file) }

        let summary = try await harness.model.exportSettings(to: file)
        #expect(summary.documentNames.contains(AppearanceSettings.name))

        harness.model.appearanceBinding(\.soundVolume).wrappedValue = 0.1
        let report = try await harness.model.importSettings(from: file)
        #expect(report.appliedCount > 0)
        #expect(SettingsStore(directory: harness.directory).load(AppearanceSettings.self).soundVolume == 0.42)
    }

    @Test func resetAppSettingsMovesDocumentsIntoABackupFolder() async throws {
        let harness = Harness(accessibility: .granted)
        harness.model.appearanceBinding(\.soundVolume).wrappedValue = 0.42
        await harness.model.settings.flush()
        let backup = try await harness.model.resetAppSettings()
        #expect(backup != nil)
        #expect(SettingsStore(directory: harness.directory).load(AppearanceSettings.self) == AppearanceSettings.defaultValue)
    }

    @Test func copyDiagnosticsWritesAReportWithoutTouchingTheRealPasteboard() {
        let harness = Harness(accessibility: .granted)
        let clipboard = FakeClipboard()
        harness.model.copyDiagnostics(to: clipboard)
        #expect(clipboard.copiedText?.contains("sTools") == true)
    }

    /// Copy Diagnostics reports every permission's state as macOS has it now, read with the checks that never ask, so
    /// copying a report brings up no prompt.
    @Test func copyDiagnosticsReportsEveryPermissionWithoutAsking() {
        let harness = Harness(accessibility: .granted)
        harness.prober.set(.screenRecording, .denied)
        harness.prober.set(.appAudio, .unknown)
        harness.prober.set(.microphone, .notDetermined)
        harness.prober.set(.camera, .granted)
        let clipboard = FakeClipboard()
        harness.model.copyDiagnostics(to: clipboard)
        let text = clipboard.copiedText ?? ""
        #expect(text.contains("  Accessibility: granted\n"))
        #expect(text.contains("  Screen & System Audio Recording: denied\n"))
        #expect(text.contains("  App audio: unknown\n"))
        #expect(text.contains("  Microphone: not determined\n"))
        #expect(text.contains("  Camera: granted\n"))
        #expect(!text.contains("not reported"))
        #expect(harness.prober.requested.isEmpty, "nothing asked macOS for a permission")

        // A permission changed since the app last read it is reported as it is now.
        harness.prober.set(.camera, .denied)
        harness.model.copyDiagnostics(to: clipboard)
        #expect(clipboard.copiedText?.contains("  Camera: denied\n") == true)
        #expect(harness.prober.requested.isEmpty)
    }

    /// The report's header says whether hotkeys are on, Where hotkeys work and the key set the tools' keys follow.
    @Test func copyDiagnosticsSaysHowHotkeysAreSet() {
        let fresh = Harness(accessibility: .granted, hotkeys: nil)
        let clipboard = FakeClipboard()
        fresh.model.copyDiagnostics(to: clipboard)
        let header = (clipboard.copiedText ?? "").components(separatedBy: "\n\n").first ?? ""
        #expect(header.contains("\nHotkeys: on\nWhere hotkeys work: In sTools and Minecraft\nKey set: \(HotkeyKeySet.command.title)"))

        let custom = Harness(accessibility: .granted)
        custom.model.hotkeys.scope = .everywhere
        custom.model.copyDiagnostics(to: clipboard)
        let customHeader = (clipboard.copiedText ?? "").components(separatedBy: "\n\n").first ?? ""
        #expect(customHeader.contains("\nHotkeys: off\nWhere hotkeys work: Everywhere\nKey set: \(HotkeyKeySet.name(of: custom.model.hotkeys.keySet))"))
    }

    @MainActor
    @Test func resetAllToolsToDefaultResetsEveryToolButNotGeneralOrAppearance() {
        let harness = Harness(accessibility: .granted, usesRealControllers: true)
        harness.model.generalBinding(\.restoreToolsAtQuit).wrappedValue = true
        harness.model.appearanceBinding(\.soundVolume).wrappedValue = 0.1
        harness.model.controller(for: .crosshair, as: CrosshairController.self)?.settings.size = 42

        harness.model.resetAllToolsToDefault()

        #expect(harness.model.controller(for: .crosshair, as: CrosshairController.self)?.settings.size == CrosshairSettings.defaultValue.size)
        #expect(harness.model.general.restoreToolsAtQuit, "General is untouched by the per-tool reset")
        #expect(harness.model.appearance.soundVolume == 0.1, "Appearance is untouched by the per-tool reset")
    }

    @Test func resetAllToolsNamesEveryToolItResetsInSidebarOrder() {
        #expect(AppModel.resetAllToolsMessage.hasPrefix(
            "This sets the settings of Crosshair, Timer Overlay, NBB Overlay, Screen Recording, Window Backdrop and "
                + "Key Rebinder back to their defaults."))
        #expect(AppModel.resetAllToolsMessage.contains("Screen Recording\u{2019}s sources and layout"))
    }
}
