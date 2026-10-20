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
}
