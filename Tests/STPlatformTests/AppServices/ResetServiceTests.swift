import Foundation
import Testing
@testable import STPlatform

@MainActor
private final class Sandbox {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "sTools-reset-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        let directory = directory
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appending(path: "Images").path)
        try? FileManager.default.removeItem(at: directory)
    }

    func put(_ text: String, _ relative: String) throws {
        let url = directory.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func exists(_ relative: String, in base: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (base ?? directory).appending(path: relative).path)
    }

    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@Suite struct ResetServiceTests {
    @Test func resetMovesEverythingIntoABackupAndRestoresDefaults() async throws {
        let box = try Sandbox()
        let store = SettingsStore(directory: box.directory)
        store.save(GeneralSettings(restoreToolsAtQuit: true, toolsOnAtQuit: ["crosshair"]))
        store.save(AppState(prologueCompleted: true, prologueStep: 5))
        await store.flush()
        try box.put("png", "Images/logo.png")
        try box.put("{}", "general.corrupt-1.json")

        let backup = try #require(try await ResetService(directory: box.directory, store: store, now: { fixedDate }).reset(confirmed: true))

        #expect(box.names() == ["Backups"])
        #expect(backup.deletingLastPathComponent().lastPathComponent == "Backups")
        #expect(backup.lastPathComponent.hasSuffix("-reset"))
        #expect(box.exists("general.json", in: backup))
        #expect(box.exists("appState.json", in: backup))
        #expect(box.exists("Images/logo.png", in: backup))
        #expect(box.exists("general.corrupt-1.json", in: backup))

        let fresh = SettingsStore(directory: box.directory)
        #expect(fresh.load(AppState.self) == AppState.defaultValue)
        #expect(fresh.load(AppState.self).prologueCompleted == false)
        #expect(fresh.load(GeneralSettings.self) == GeneralSettings.defaultValue)
    }

    @Test func resetFlushesPendingWritesSoTheyAreNotLost() async throws {
        let box = try Sandbox()
        let store = SettingsStore(directory: box.directory, debounce: .seconds(60))
        store.save(AppState(prologueCompleted: true, prologueStep: 2))

        let backup = try #require(try await ResetService(directory: box.directory, store: store).reset(confirmed: true))

        #expect(box.exists("appState.json", in: backup))
        #expect(box.names() == ["Backups"])
        #expect(SettingsStore(directory: box.directory).load(AppState.self) == AppState.defaultValue)
    }

    @Test func resetWithoutConfirmationChangesNothing() async throws {
        let box = try Sandbox()
        try box.put("{}", "general.json")
        await #expect(throws: ResetError.notConfirmed) {
            try await ResetService(directory: box.directory).reset(confirmed: false)
        }
        #expect(box.names() == ["general.json"])
    }

    @Test func resetKeepsEarlierBackups() async throws {
        let box = try Sandbox()
        try box.put("old", "Backups/20260101-000000-reset/general.json")
        try box.put("{}", "general.json")
        _ = try await ResetService(directory: box.directory, now: { fixedDate }).reset(confirmed: true)
        try box.put("{}", "general.json")
        _ = try await ResetService(directory: box.directory, now: { fixedDate }).reset(confirmed: true)

        let backups = try FileManager.default.contentsOfDirectory(atPath: box.directory.appending(path: "Backups").path)
        #expect(backups.count == 3)
        #expect(box.exists("Backups/20260101-000000-reset/general.json"))
    }

    @Test func resettingAnEmptyOrMissingDirectoryIsANoOp() async throws {
        let box = try Sandbox()
        #expect(try await ResetService(directory: box.directory).reset(confirmed: true) == nil)
        let missing = box.directory.appending(path: "missing")
        #expect(try await ResetService(directory: missing).reset(confirmed: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func aFailedMoveRestoresWhatWasAlreadyMoved() async throws {
        let box = try Sandbox()
        // Items move in name order, so "A.json" is already moved when "Images" fails.
        try box.put("a", "A.json")
        try box.put("img", "Images/x.png")
        // A directory cannot be renamed into another parent without write access to itself.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.directory.appending(path: "Images").path)

        do {
            _ = try await ResetService(directory: box.directory, now: { fixedDate }).reset(confirmed: true)
            Issue.record("the reset should have failed")
        } catch ResetError.moveFailed {
        }

        #expect(box.exists("A.json"))
        #expect(box.exists("Images/x.png"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: box.directory.appending(path: "Backups").path)) ?? []).isEmpty)
    }

    @Test func aFailedBackupFolderChangesNothing() async throws {
        let box = try Sandbox()
        try box.put("a", "a.json")
        try box.put("not a folder", "Backups")
        do {
            _ = try await ResetService(directory: box.directory).reset(confirmed: true)
            Issue.record("the reset should have failed")
        } catch ResetError.backupFailed {
        }
        #expect(box.exists("a.json"))
    }
}
