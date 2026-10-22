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

    // MARK: The Timer trial's step 10 (spec 4)

    /// `appState.json` as a build from before the Timer trial reads and writes it: 15 steps, version 1.
    private struct AppStateBeforeTimerTrial: SettingsDocument {
        static let name = "appState"
        static let version = 1
        static let defaultValue = AppStateBeforeTimerTrial(prologueCompleted: false, prologueStep: 0)

        var prologueCompleted: Bool
        var prologueStep: Int

        init(prologueCompleted: Bool, prologueStep: Int) {
            self.prologueCompleted = prologueCompleted
            self.prologueStep = prologueStep
        }

        private enum CodingKeys: String, CodingKey {
            case prologueCompleted, prologueStep
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prologueCompleted = try container.decodeIfPresent(Bool.self, forKey: .prologueCompleted) ?? false
            prologueStep = try container.decodeIfPresent(Int.self, forKey: .prologueStep) ?? 0
        }
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// An old file's steps before the Timer trial's place stay; from old step 10 (Window Backdrop's trial) on,
    /// they move up by one. Window Backdrop's trial itself, which that build showed before NBB Overlay's, resumes at
    /// NBB Overlay's (revision 12's trial order).
    @Test(arguments: [(0, 0), (1, 1), (8, 8), (9, 11), (10, 11), (11, 12), (13, 14), (14, 15)])
    func anOldFilesStepMovesAcrossTheTimerTrial(old: Int, new: Int) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"version":1,"value":{"prologueCompleted":false,"prologueStep":\#(old)}}"#.utf8)
            .write(to: directory.appending(path: "appState.json"))
        let store = SettingsStore(directory: directory)
        #expect(store.load(AppState.self) == AppState(prologueCompleted: false, prologueStep: new))
        #expect(try files(in: directory) == ["appState.json"])
    }

    @Test func anOldFinishedIntroductionStaysFinished() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"version":1,"value":{"prologueCompleted":true,"prologueStep":0}}"#.utf8)
            .write(to: directory.appending(path: "appState.json"))
        #expect(SettingsStore(directory: directory).load(AppState.self).prologueCompleted)
    }

    @Test(arguments: 0..<16)
    func everyStepRoundTripsInTheNewFile(step: Int) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.save(AppState(prologueCompleted: false, prologueStep: step))
        await store.flush()
        #expect(SettingsStore(directory: directory).load(AppState.self) == AppState(prologueCompleted: false, prologueStep: step))
    }

    @Test func theNewFileKeepsVersionOneAndTheOldKey() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.save(AppState(prologueCompleted: false, prologueStep: 12))
        await store.flush()
        let data = try Data(contentsOf: directory.appending(path: "appState.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try #require(json["value"] as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(value["prologueStep"] as? Int == 11)
        #expect(value["prologueStepWithTimerTrial"] as? Int == 12)
    }

    /// A build from before the Timer trial reads the new file without moving it aside, so a finished introduction
    /// stays finished there.
    @Test func anOlderBuildKeepsAFinishedIntroductionFinished() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.save(AppState(prologueCompleted: true, prologueStep: 0))
        await store.flush()

        let older = SettingsStore(directory: directory).load(AppStateBeforeTimerTrial.self)
        #expect(older.prologueCompleted)
        #expect(try files(in: directory) == ["appState.json"])
    }

    /// An unfinished introduction resumes in an older build at the same step, and the Timer trial at the step after
    /// it there, Window Backdrop's trial; never back at the greeting.
    @Test(arguments: [(0, 0), (8, 8), (9, 9), (10, 9), (11, 10), (15, 14)])
    func anOlderBuildResumesAtTheSameStep(new: Int, old: Int) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.save(AppState(prologueCompleted: false, prologueStep: new))
        await store.flush()

        let older = SettingsStore(directory: directory).load(AppStateBeforeTimerTrial.self)
        #expect(older == AppStateBeforeTimerTrial(prologueCompleted: false, prologueStep: old))
        #expect(try files(in: directory) == ["appState.json"])
    }

    /// What an older build saves after the new one comes back to the new one at the same step.
    @Test func aStepSavedByAnOlderBuildComesBackAcrossTheTimerTrial() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.save(AppState(prologueCompleted: false, prologueStep: 12))
        await store.flush()

        let olderStore = SettingsStore(directory: directory)
        olderStore.save(olderStore.load(AppStateBeforeTimerTrial.self))
        await olderStore.flush()

        #expect(SettingsStore(directory: directory).load(AppState.self) == AppState(prologueCompleted: false, prologueStep: 12))
    }

    // MARK: The Trials in sidebar order (revision 12)

    /// A file from a build that showed the Trials in the old order has no `trialsInSidebarOrder`: its Window Backdrop
    /// trial (index 10) resumes at NBB Overlay's (11); every other step stays.
    @Test(arguments: [(8, 8), (9, 9), (10, 11), (11, 11), (12, 12), (13, 13), (15, 15)])
    func aFileFromTheOldTrialOrderLeavesNoTrialSkipped(saved: Int, resumed: Int) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = saved > AppState.timerTrialIndex ? saved - 1 : saved
        try Data(#"{"version":1,"value":{"prologueCompleted":false,"prologueStep":\#(old),"prologueStepWithTimerTrial":\#(saved)}}"#.utf8)
            .write(to: directory.appending(path: "appState.json"))
        #expect(SettingsStore(directory: directory).load(AppState.self) == AppState(prologueCompleted: false, prologueStep: resumed))
    }

    @Test func theNewFileMarksItsTrialOrder() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.save(AppState(prologueCompleted: false, prologueStep: AppState.backdropTrialIndex))
        await store.flush()
        let data = try Data(contentsOf: directory.appending(path: "appState.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try #require(json["value"] as? [String: Any])
        #expect(value["trialsInSidebarOrder"] as? Bool == true)
        #expect(SettingsStore(directory: directory).load(AppState.self).prologueStep == AppState.backdropTrialIndex)
    }
}
