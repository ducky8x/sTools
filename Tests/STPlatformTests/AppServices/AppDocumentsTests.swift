import Foundation
import Testing
@testable import STPlatform

@MainActor
@Suite struct AppDocumentsTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sTools-appdocs-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func generalSettingsDefaults() {
        let general = GeneralSettings.defaultValue
        #expect(GeneralSettings.name == "general")
        #expect(GeneralSettings.version == 1)
        #expect(general.restoreToolsAtQuit == false)
        #expect(general.toolsOnAtQuit.isEmpty)
    }

    @Test func appStateDefaults() {
        let state = AppState.defaultValue
        #expect(AppState.name == "appState")
        #expect(AppState.version == 1)
        #expect(state.prologueCompleted == false)
        #expect(state.prologueStep == 0)
    }

    @Test func documentsRoundTripThroughTheStore() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.save(GeneralSettings(restoreToolsAtQuit: true, toolsOnAtQuit: ["crosshair", "backdrop"]))
        store.save(AppState(prologueCompleted: true, prologueStep: 4))
        await store.flush()

        let reloaded = SettingsStore(directory: directory)
        #expect(reloaded.load(GeneralSettings.self) == GeneralSettings(restoreToolsAtQuit: true, toolsOnAtQuit: ["crosshair", "backdrop"]))
        #expect(reloaded.load(AppState.self) == AppState(prologueCompleted: true, prologueStep: 4))
    }

    @Test func missingKeysDecodeToDefaults() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"version":1,"value":{}}"#.utf8).write(to: directory.appending(path: "general.json"))
        try Data(#"{"version":1,"value":{"prologueStep":2}}"#.utf8).write(to: directory.appending(path: "appState.json"))
        let store = SettingsStore(directory: directory)
        #expect(store.load(GeneralSettings.self) == GeneralSettings.defaultValue)
        #expect(store.load(AppState.self) == AppState(prologueCompleted: false, prologueStep: 2))
    }
}
