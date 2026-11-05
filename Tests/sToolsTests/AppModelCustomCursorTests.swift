import CustomCursor
import Foundation
@testable import STPlatform
import Testing
@testable import sTools

/// Custom Cursor in the app (spec 5.7): its place among the tools, its switch, hotkey, quitting, Reset sTools, export and
/// Copy Diagnostics. Every pointer swap goes through the harness's fake.
@MainActor
@Suite("Custom Cursor in the app")
struct AppModelCustomCursorTests {
    /// A harness with Custom Cursor's real controller over a fake swapper, replacing the pointer everywhere so no
    /// Minecraft has to be in front.
    private func harness(supported: Bool = true, accessibility: PermissionStatus = .granted) -> (Harness, FakeCursorSwapper) {
        let swapper = FakeCursorSwapper(isSupported: supported)
        let harness = Harness(accessibility: accessibility, cursorSwapper: swapper)
        harness.model.customCursor?.settings.where = .everywhere
        return (harness, swapper)
    }

    // MARK: Its place

    @Test func itIsTheSixthToolBeforeTheKeyRebinder() {
        #expect(ToolID.allCases == [.crosshair, .timerOverlay, .nbbOverlay, .screenRecording, .windowBackdrop, .customCursor, .keyRebinder])
        let tool = ToolID.customCursor
        #expect(tool.number == 6)
        #expect(ToolID.keyRebinder.number == 7)
        #expect(tool.title == "Custom Cursor")
        #expect(tool.sidebarTitle == "Cursor")
        #expect(tool.tagline == "Your own pointer for Minecraft\u{2019}s menus.")
        #expect(tool.requiresAccessibility, "rule R10, like the other overlay tools")
        #expect(tool.hasSwitch)
        #expect(tool.hotkeyTool == .cursor)
        #expect(tool.hotkeyAction == .toggle(.cursor))
        #expect(tool.trial == nil, "no Prologue trial yet")
        #expect(GoCommand.tool(tool).shortcutDisplay == "⌃⌘6")
        #expect(GoCommand.tool(.keyRebinder).shortcutDisplay == "⌃⌘7")
    }

    // MARK: The switch

    @Test func theSwitchAppliesAndRestores() {
        let (harness, swapper) = harness()
        harness.model.userSwitched(.customCursor, on: true)
        #expect(harness.model.isOn(.customCursor))
        #expect(harness.model.status(of: .customCursor) == .on)
        #expect(swapper.showsCustomPointer)
        harness.model.userSwitched(.customCursor, on: false)
        #expect(!swapper.showsCustomPointer)
        #expect(swapper.restoreCount == 1)
    }

    /// Rule R10: without Accessibility it can't switch on, and a revoked grant switches it off and puts the arrow back.
    @Test func itNeedsAccessibility() {
        let (denied, deniedSwapper) = harness(accessibility: .denied)
        #expect(!denied.model.canSwitch(.customCursor))
        #expect(denied.model.status(of: .customCursor) == .needsAccessibility)
        denied.model.setTool(.customCursor, on: true)
        #expect(deniedSwapper.applyCount == 0)

        let (granted, swapper) = harness()
        granted.model.setTool(.customCursor, on: true)
        granted.prober.set(.accessibility, .denied)
        granted.model.permissions.refresh()
        granted.model.reconcileAccessibility()
        #expect(!granted.model.isOn(.customCursor))
        #expect(!swapper.showsCustomPointer)
    }

    /// Without the pointer calls the tool says so and its switch stays off.
    @Test func withoutTheCallsTheSwitchIsDisabled() {
        let (harness, swapper) = harness(supported: false)
        #expect(!harness.model.isSupported(.customCursor))
        #expect(!harness.model.canSwitch(.customCursor))
        #expect(harness.model.status(of: .customCursor) == .notSupported)
        #expect(ToolStatus.notSupported.label == "NOT SUPPORTED")
        #expect(!ToolStatus.notSupported.isLit)
        harness.model.userSwitched(.customCursor, on: true)
        #expect(!harness.model.isOn(.customCursor))
        #expect(swapper.applyCount == 0)
        #expect(harness.model.isSupported(.crosshair), "every other tool runs as before")
    }

    // MARK: Its hotkey

    @Test func itsHotkeySwitchesIt() {
        let (harness, swapper) = harness()
        let effect = harness.model.handleHotkeyEvent(.setTool(.cursor, isOn: true))
        #expect(effect == .tool(.customCursor, isOn: true))
        #expect(swapper.showsCustomPointer)
        _ = harness.model.handleHotkeyEvent(.setTool(.cursor, isOn: false))
        #expect(!swapper.showsCustomPointer)
        #expect(harness.model.hotkeyToolStates()[.cursor] == false)
    }

    // MARK: Quitting and Reset sTools

    @Test func quittingRestoresThePointer() async {
        let (harness, swapper) = harness()
        harness.model.setTool(.customCursor, on: true)
        await harness.model.shutDown()
        #expect(!swapper.showsCustomPointer)
        #expect(swapper.restoreCount == 1)
    }

    /// `applicationWillTerminate` puts the arrow back whatever the switch says, and only once.
    @Test func theLastStepOfQuittingRestoresWhatsStillApplied() {
        let (harness, swapper) = harness()
        harness.model.setTool(.customCursor, on: true)
        harness.model.restorePointerForQuit()
        #expect(!swapper.showsCustomPointer)
        harness.model.restorePointerForQuit()
        #expect(swapper.restoreCount == 1)
    }

    /// Reset sTools switches it off and puts the arrow back before its files go into the backup with the rest.
    @Test func resetSToolsRestoresFirst() async throws {
        let (harness, swapper) = harness()
        harness.model.setTool(.customCursor, on: true)
        #expect(FileManager.default.fileExists(atPath: harness.directory.appending(path: "Cursor/applied").path))
        let backup = try #require(try await harness.model.resetAppSettings())
        #expect(!harness.model.isOn(.customCursor))
        #expect(swapper.restoreCount == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: "Cursor").path))
        #expect(!FileManager.default.fileExists(atPath: backup.appending(path: "Cursor/applied").path), "no marker left to restore from")
    }

    @Test func resetAllToolsResetsItsSettings() {
        let (harness, _) = harness()
        harness.model.customCursor?.settings.size = 40
        harness.model.resetAllToolsToDefault()
        #expect(harness.model.customCursor?.settings == .defaultValue)
        #expect(AppModel.resetAllToolsMessage.contains("Custom Cursor"))
    }

    // MARK: Export, import and Copy Diagnostics

    @Test func itsSettingsTravelWithExportAndImport() async throws {
        let (harness, _) = harness()
        #expect(AppModel.knownSettingsVersions[CustomCursorSettings.name] == CustomCursorSettings.version)
        let file = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).stools-settings")
        defer { try? FileManager.default.removeItem(at: file) }
        harness.model.customCursor?.settings.size = 33
        await harness.model.settings.flush()
        let summary = try await harness.model.exportSettings(to: file)
        #expect(summary.documentNames.contains(CustomCursorSettings.name))

        harness.model.customCursor?.settings.size = 20
        await harness.model.settings.flush()
        let report = try await harness.model.importSettings(from: file)
        #expect(report.documents.first { $0.name == CustomCursorSettings.name }?.outcome == .applied)
        #expect(SettingsStore(directory: harness.directory).load(CustomCursorSettings.self).size == 33)
    }

    @Test func copyDiagnosticsSaysWhatItIsDoing() {
        let (harness, _) = harness()
        let clipboard = FakeClipboard()
        harness.model.copyDiagnostics(to: clipboard)
        #expect(clipboard.copiedText?.contains("Custom Cursor: Off, not applied, Everywhere, calls found") == true)
        harness.model.setTool(.customCursor, on: true)
        harness.model.copyDiagnostics(to: clipboard)
        #expect(clipboard.copiedText?.contains("Custom Cursor: On, applied now, Everywhere, calls found") == true)
        #expect(clipboard.copiedText?.contains("Enabled tools: Custom Cursor") == true)
        harness.model.setTool(.customCursor, on: false)
    }
}
