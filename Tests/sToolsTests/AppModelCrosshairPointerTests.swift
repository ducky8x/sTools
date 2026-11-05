@testable import Crosshair
import Foundation
@testable import STPlatform
import Testing
@testable import sTools

/// The Crosshair's menu settings in the app: quitting, Reset sTools, export and import, and an old Custom Cursor file.
/// Every pointer read and swap goes through the harness's fakes.
@MainActor
@Suite("Crosshair pointer in the app")
struct AppModelCrosshairPointerTests {
    /// A harness whose Crosshair is real over pointer fakes, with Minecraft in front, and Be the pointer on.
    private func harness() -> (Harness, CrosshairPointerFakes) {
        let fakes = CrosshairPointerFakes()
        let window = MinecraftWindow(windowNumber: 100, processID: 100, title: "Minecraft* 1.16.1", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let minecraft = MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1), isFrontmost: true, displayID: 1)
        let harness = Harness(instances: [minecraft], crosshairPointer: fakes)
        harness.model.minecraft.refresh()
        harness.model.crosshair?.settings.isPointerInMinecraftMenus = true
        return (harness, fakes)
    }

    @Test func theSwitchMakesItThePointer() {
        let (harness, fakes) = harness()
        harness.model.userSwitched(.crosshair, on: true)
        #expect(fakes.swapper.showsTheCrosshair)
        #expect(fakes.watch.isWatching)
        fakes.watch.pointerShows = true
        #expect(harness.model.crosshair?.isOverlayShown == false, "in a menu the pointer is the crosshair")
        harness.model.userSwitched(.crosshair, on: false)
        #expect(!fakes.swapper.showsTheCrosshair)
        #expect(!fakes.watch.isWatching)
    }

    @Test func itsHotkeySwitchesThePointerToo() {
        let (harness, fakes) = harness()
        _ = harness.model.handleHotkeyEvent(.setTool(.crosshair, isOn: true))
        #expect(fakes.swapper.showsTheCrosshair)
        _ = harness.model.handleHotkeyEvent(.setTool(.crosshair, isOn: false))
        #expect(!fakes.swapper.showsTheCrosshair)
    }

    /// Rule R10: a revoked Accessibility grant switches the Crosshair off, and the arrow goes back with it.
    @Test func losingAccessibilityPutsTheArrowBack() {
        let (harness, fakes) = harness()
        harness.model.setTool(.crosshair, on: true)
        harness.prober.set(.accessibility, .denied)
        harness.model.permissions.refresh()
        harness.model.reconcileAccessibility()
        #expect(!harness.model.isOn(.crosshair))
        #expect(!fakes.swapper.showsTheCrosshair)
    }

    // MARK: Quitting and Reset sTools

    @Test func quittingPutsTheArrowBack() async {
        let (harness, fakes) = harness()
        harness.model.setTool(.crosshair, on: true)
        await harness.model.shutDown()
        #expect(!fakes.swapper.showsTheCrosshair)
        #expect(fakes.swapper.restoreCount == 1)
    }

    /// `applicationWillTerminate` puts the arrow back whatever the switch says, once, and nothing swaps it again.
    @Test func theLastStepOfQuittingRestoresWhatsStillApplied() {
        let (harness, fakes) = harness()
        harness.model.setTool(.crosshair, on: true)
        harness.model.restorePointerForQuit()
        #expect(!fakes.swapper.showsTheCrosshair)
        harness.model.restorePointerForQuit()
        harness.model.crosshair?.settings.size = 20
        #expect(fakes.swapper.restoreCount == 1)
        #expect(fakes.swapper.applyCount == 1)
    }

    /// Reset sTools puts the arrow back before the pointer's files go into the backup with the rest, and leaves no
    /// marker for the next launch to restore from.
    @Test func resetSToolsRestoresFirst() async throws {
        let (harness, fakes) = harness()
        harness.model.setTool(.crosshair, on: true)
        #expect(FileManager.default.fileExists(atPath: harness.directory.appending(path: "Cursor/applied").path))
        let backup = try #require(try await harness.model.resetAppSettings())
        #expect(!fakes.swapper.showsTheCrosshair)
        #expect(fakes.swapper.restoreCount == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: "Cursor/applied").path))
        #expect(!FileManager.default.fileExists(atPath: backup.appending(path: "Cursor/applied").path), "no marker left to restore from")
        harness.model.crosshair?.settings.fillHex = "#E4BC62"
        #expect(fakes.swapper.applyCount == 1, "until the relaunch, the arrow stays macOS's")
    }

    @Test func resetAllToolsTurnsTheSettingsOff() {
        let (harness, fakes) = harness()
        harness.model.setTool(.crosshair, on: true)
        harness.model.crosshair?.settings.hidesInMinecraftMenus = true
        harness.model.resetAllToolsToDefault()
        #expect(harness.model.crosshair?.settings.isPointerInMinecraftMenus == false)
        #expect(harness.model.crosshair?.settings.hidesInMinecraftMenus == false)
        #expect(!fakes.swapper.showsTheCrosshair)
        #expect(!fakes.watch.isWatching)
    }

    // MARK: Export and import

    @Test func theSettingsTravelWithExportAndImport() async throws {
        let (harness, _) = harness()
        harness.model.crosshair?.settings.hidesInMinecraftMenus = true
        await harness.model.settings.flush()
        let file = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).stools-settings")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await harness.model.exportSettings(to: file)

        harness.model.crosshair?.settings.hidesInMinecraftMenus = false
        harness.model.crosshair?.settings.isPointerInMinecraftMenus = false
        await harness.model.settings.flush()
        let report = try await harness.model.importSettings(from: file)
        #expect(report.documents.first { $0.name == CrosshairSettings.name }?.outcome == .applied)
        let imported = SettingsStore(directory: harness.directory).load(CrosshairSettings.self)
        #expect(imported.hidesInMinecraftMenus)
        #expect(imported.isPointerInMinecraftMenus)
    }

    // MARK: Custom Cursor's file

    /// Earlier builds' Custom Cursor saved `cursor.json`. This build reads no such document: an import skips it as one it
    /// doesn't know, and the Crosshair's settings don't change.
    @Test func anOldCursorFileIsIgnored() async throws {
        let (harness, fakes) = harness()
        let cursorFile = #"{"version":1,"value":{"shape":"dot","size":40,"where":"everywhere"}}"#
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        try Data(cursorFile.utf8).write(to: harness.directory.appending(path: "cursor.json"))
        #expect(AppModel.knownSettingsVersions["cursor"] == nil)
        harness.model.setTool(.crosshair, on: true)
        #expect(harness.model.crosshair?.settings.size == CrosshairSettings.defaultValue.size)

        let file = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).stools-settings")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await harness.model.exportSettings(to: file)
        let report = try await harness.model.importSettings(from: file)
        #expect(report.documents.first { $0.name == "cursor" }?.outcome == .skipped(.unknownDocument))
        #expect(fakes.swapper.applyCount == 1)
        harness.model.setTool(.crosshair, on: false)
    }
}
