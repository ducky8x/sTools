import Foundation
import Testing
@testable import STPlatform

@MainActor
private final class Sandbox {
    let root: URL
    let source: URL
    let target: URL
    let file: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "sTools-backup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        source = root.appending(path: "source", directoryHint: .isDirectory)
        target = root.appending(path: "target", directoryHint: .isDirectory)
        file = root.appending(path: "export.stools-settings")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }

    deinit {
        let root = root
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appending(path: "target/Images").path)
        try? FileManager.default.removeItem(at: root)
    }

    func put(_ text: String, _ relative: String, in directory: URL) throws {
        let url = directory.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func doc(_ name: String, version: Int = 1, value: String, in directory: URL) throws {
        try put(#"{"version":\#(version),"value":\#(value)}"#, "\(name).json", in: directory)
    }

    func text(_ relative: String, in directory: URL) -> String? {
        (try? Data(contentsOf: directory.appending(path: relative))).flatMap { String(data: $0, encoding: .utf8) }
    }

    func backupFolders(in directory: URL) -> [URL] {
        let backups = directory.appending(path: "Backups")
        return ((try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func writeEnvelope(_ json: String) throws {
        try Data(json.utf8).write(to: file)
    }

    func jsonObject(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
private let known = ["general": 1, "appState": 1, "crosshair": 2]

@MainActor
@Suite struct SettingsBackupTests {
    // MARK: Export

    @Test func exportWritesAVersionedEnvelope() async throws {
        let box = try Sandbox()
        try box.doc("general", value: #"{"restoreToolsAtQuit":true,"toolsOnAtQuit":["crosshair"]}"#, in: box.source)
        try box.doc("crosshair", version: 2, value: #"{"size":12.5,"visible":true}"#, in: box.source)
        try box.put("not a document", "notes.txt", in: box.source)
        try box.put("{}", "general.corrupt-20260101.json", in: box.source)
        try box.put("garbage", "broken.json", in: box.source)

        let summary = try await SettingsBackup(directory: box.source, now: { fixedDate }).export(to: box.file)
        #expect(summary.documentNames == ["crosshair", "general"])
        #expect(summary.imageCount == 0)

        let root = try box.jsonObject(box.file)
        #expect(root["format"] as? Int == 1)
        #expect(root["app"] as? String == "sTools")
        #expect(root["createdAt"] as? String == fixedDate.formatted(.iso8601))
        let documents = try #require(root["documents"] as? [String: Any])
        #expect(Set(documents.keys) == ["general", "crosshair"])
        let crosshair = try #require(documents["crosshair"] as? [String: Any])
        #expect(crosshair["version"] as? Int == 2)
        let value = try #require(crosshair["value"] as? [String: Any])
        #expect(value["size"] as? Double == 12.5)
        #expect(value["visible"] as? Bool == true)
    }

    @Test func exportFlushesPendingStoreWrites() async throws {
        let box = try Sandbox()
        let store = SettingsStore(directory: box.source, debounce: .seconds(60))
        store.save(GeneralSettings(restoreToolsAtQuit: true, toolsOnAtQuit: ["backdrop"]))

        _ = try await SettingsBackup(directory: box.source, store: store).export(to: box.file)

        let documents = try #require(try box.jsonObject(box.file)["documents"] as? [String: Any])
        #expect(documents["general"] != nil)
    }

    @Test func exportNeverIncludesTheBackupsFolder() async throws {
        let box = try Sandbox()
        try box.doc("general", value: "{}", in: box.source)
        try box.doc("old", value: "{}", in: box.source.appending(path: "Backups/20260101-000000-reset"))
        let summary = try await SettingsBackup(directory: box.source).export(to: box.file)
        #expect(summary.documentNames == ["general"])
    }

    // MARK: Round trip

    @Test func roundTripRestoresDocumentsAndImages() async throws {
        let box = try Sandbox()
        try box.doc("general", value: #"{"restoreToolsAtQuit":true,"toolsOnAtQuit":["a","b"]}"#, in: box.source)
        try box.doc("crosshair", version: 2, value: #"{"size":12.5,"nested":{"list":[1,2,3],"flag":false}}"#, in: box.source)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x10, 0x80])
        let images = box.source.appending(path: "Images")
        try FileManager.default.createDirectory(at: images.appending(path: "sub"), withIntermediateDirectories: true)
        try png.write(to: images.appending(path: "logo.png"))
        try Data(png.reversed()).write(to: images.appending(path: "sub/deep.png"))

        let exported = try await SettingsBackup(directory: box.source).export(to: box.file)
        #expect(exported.imageCount == 2)

        let report = try await SettingsBackup(directory: box.target, now: { fixedDate })
            .importSettings(from: box.file, knownVersions: known)

        #expect(report.documents.map(\.name) == ["crosshair", "general"])
        #expect(report.documents.allSatisfy { $0.outcome == .applied })
        #expect(report.images.map(\.name) == ["logo.png", "sub/deep.png"])
        #expect(report.images.allSatisfy { $0.outcome == .applied })
        #expect(report.backupURL == nil)

        let store = SettingsStore(directory: box.target)
        #expect(store.load(GeneralSettings.self) == GeneralSettings(restoreToolsAtQuit: true, toolsOnAtQuit: ["a", "b"]))
        let crosshair = try box.jsonObject(box.target.appending(path: "crosshair.json"))
        #expect(crosshair["version"] as? Int == 2)
        #expect(try Data(contentsOf: box.target.appending(path: "Images/logo.png")) == png)
        #expect(try Data(contentsOf: box.target.appending(path: "Images/sub/deep.png")) == Data(png.reversed()))
    }

    @Test func importBacksUpCurrentSettingsFirstAndKeepsOtherDocuments() async throws {
        let box = try Sandbox()
        try box.doc("general", value: #"{"restoreToolsAtQuit":true}"#, in: box.source)
        try box.doc("general", value: #"{"restoreToolsAtQuit":false,"toolsOnAtQuit":["old"]}"#, in: box.target)
        try box.doc("appState", value: #"{"prologueCompleted":true}"#, in: box.target)
        try box.put("old image", "Images/keep.png", in: box.target)
        _ = try await SettingsBackup(directory: box.source).export(to: box.file)

        let report = try await SettingsBackup(directory: box.target, now: { fixedDate })
            .importSettings(from: box.file, knownVersions: known)

        let backup = try #require(report.backupURL)
        #expect(backup.deletingLastPathComponent().lastPathComponent == "Backups")
        #expect(backup.lastPathComponent.hasSuffix("-before-import"))
        #expect(box.text("general.json", in: backup)?.contains("old") == true)
        #expect(box.text("appState.json", in: backup) != nil)
        #expect(box.text("Images/keep.png", in: backup) == "old image")
        #expect(box.backupFolders(in: box.target).count == 1)

        #expect(box.text("general.json", in: box.target)?.contains("old") == false)
        #expect(box.text("appState.json", in: box.target)?.contains("true") == true)
        #expect(box.text("Images/keep.png", in: box.target) == "old image")
    }

    @Test func olderDocumentVersionsAreAppliedAsIsForTheStoreToMigrate() async throws {
        let box = try Sandbox()
        try box.doc("crosshair", version: 1, value: #"{"size":3}"#, in: box.source)
        _ = try await SettingsBackup(directory: box.source).export(to: box.file)
        let report = try await SettingsBackup(directory: box.target).importSettings(from: box.file, knownVersions: known)
        #expect(report.documents == [.init(name: "crosshair", outcome: .applied)])
        #expect(try box.jsonObject(box.target.appending(path: "crosshair.json"))["version"] as? Int == 1)
    }

    // MARK: Rejections

    @Test func corruptFileIsRefusedAndNothingChanges() async throws {
        let box = try Sandbox()
        try box.doc("general", value: #"{"restoreToolsAtQuit":true}"#, in: box.target)
        let before = box.text("general.json", in: box.target)
        for junk in ["not json at all", "[1,2,3]", "{}", #"{"format":1,"app":"sTools"}"#, #"{"format":1,"app":"sTools","documents":[]}"#] {
            try box.writeEnvelope(junk)
            await #expect(throws: SettingsBackupError.notABackup) {
                try await SettingsBackup(directory: box.target).importSettings(from: box.file, knownVersions: known)
            }
        }
        #expect(box.text("general.json", in: box.target) == before)
        #expect(box.backupFolders(in: box.target).isEmpty)
    }

    @Test func missingFileIsReportedAsUnreadable() async throws {
        let box = try Sandbox()
        await #expect(throws: SettingsBackupError.self) {
            try await SettingsBackup(directory: box.target).importSettings(from: box.root.appending(path: "nope"), knownVersions: known)
        }
    }

    @Test func newerFormatIsRefused() async throws {
        let box = try Sandbox()
        try box.writeEnvelope(#"{"format":2,"app":"sTools","createdAt":"x","documents":{"general":{"version":1,"value":{}}}}"#)
        await #expect(throws: SettingsBackupError.newerFormat(2)) {
            try await SettingsBackup(directory: box.target).importSettings(from: box.file, knownVersions: known)
        }
        #expect(!FileManager.default.fileExists(atPath: box.target.appending(path: "general.json").path))
    }

    @Test func foreignAppIsRefused() async throws {
        let box = try Sandbox()
        try box.writeEnvelope(#"{"format":1,"app":"SomethingElse","createdAt":"x","documents":{}}"#)
        await #expect(throws: SettingsBackupError.foreignApp("SomethingElse")) {
            try await SettingsBackup(directory: box.target).importSettings(from: box.file, knownVersions: known)
        }
        try box.writeEnvelope(#"{"format":1,"createdAt":"x","documents":{}}"#)
        await #expect(throws: SettingsBackupError.notABackup) {
            try await SettingsBackup(directory: box.target).importSettings(from: box.file, knownVersions: known)
        }
    }

    // MARK: Per-document results

    @Test func skipsWhatItCannotApplyAndAppliesTheRest() async throws {
        let box = try Sandbox()
        try box.writeEnvelope("""
        {"format":1,"app":"sTools","createdAt":"x","documents":{
          "general":{"version":1,"value":{"restoreToolsAtQuit":true}},
          "crosshair":{"version":3,"value":{}},
          "mystery":{"version":1,"value":{}},
          "appState":{"version":0,"value":{}},
          "../escape":{"version":1,"value":{}},
          "broken":"text"
        },"images":{"ok.png":"AQID","../evil.png":"AQID","bad.png":"%%%","/abs.png":"AQID"}}
        """)

        let report = try await SettingsBackup(directory: box.target)
            .importSettings(from: box.file, knownVersions: known.merging(["broken": 1]) { $1 })

        func outcome(_ name: String) -> SettingsBackup.Outcome? { report.documents.first { $0.name == name }?.outcome }
        #expect(outcome("general") == .applied)
        #expect(outcome("crosshair") == .skipped(.newerVersion(found: 3, supported: 2)))
        #expect(outcome("mystery") == .skipped(.unknownDocument))
        #expect(outcome("appState") == .skipped(.invalidEntry))
        #expect(outcome("../escape") == .skipped(.invalidName))
        #expect(outcome("broken") == .skipped(.invalidEntry))
        #expect(report.appliedCount == 2)
        #expect(report.skippedCount == 8)

        func imageOutcome(_ name: String) -> SettingsBackup.Outcome? { report.images.first { $0.name == name }?.outcome }
        #expect(imageOutcome("ok.png") == .applied)
        #expect(imageOutcome("../evil.png") == .skipped(.invalidName))
        #expect(imageOutcome("/abs.png") == .skipped(.invalidName))
        #expect(imageOutcome("bad.png") == .skipped(.invalidEntry))

        #expect(box.text("general.json", in: box.target) != nil)
        #expect(!FileManager.default.fileExists(atPath: box.target.appending(path: "crosshair.json").path))
        #expect(!FileManager.default.fileExists(atPath: box.root.appending(path: "escape.json").path))
        #expect(!FileManager.default.fileExists(atPath: box.target.appending(path: "Images/bad.png").path))
        #expect(try Data(contentsOf: box.target.appending(path: "Images/ok.png")) == Data([1, 2, 3]))
    }

    @Test func nothingApplicableMeansNoBackupAndNoWrites() async throws {
        let box = try Sandbox()
        try box.doc("general", value: "{}", in: box.target)
        try box.writeEnvelope(#"{"format":1,"app":"sTools","createdAt":"x","documents":{"mystery":{"version":1,"value":{}}}}"#)
        let report = try await SettingsBackup(directory: box.target).importSettings(from: box.file, knownVersions: known)
        #expect(report.appliedCount == 0)
        #expect(report.backupURL == nil)
        #expect(box.backupFolders(in: box.target).isEmpty)
    }

    // MARK: Atomicity

    @Test func failureMidwayRestoresThePreviousSettings() async throws {
        let box = try Sandbox()
        try box.doc("appState", value: #"{"prologueStep":3}"#, in: box.target)
        try box.doc("general", value: #"{"restoreToolsAtQuit":false}"#, in: box.target)
        try box.put("old", "Images/a.png", in: box.target)
        // A directory squatting on "crosshair.json" makes that one write fail after appState and general succeeded.
        try FileManager.default.createDirectory(at: box.target.appending(path: "crosshair.json"), withIntermediateDirectories: true)
        try box.writeEnvelope("""
        {"format":1,"app":"sTools","createdAt":"x","documents":{
          "appState":{"version":1,"value":{"prologueStep":9}},
          "general":{"version":1,"value":{"restoreToolsAtQuit":true}},
          "crosshair":{"version":2,"value":{"size":1}}
        },"images":{"a.png":"AQID","z/new.png":"AQID"}}
        """)

        do {
            _ = try await SettingsBackup(directory: box.target, now: { fixedDate }).importSettings(from: box.file, knownVersions: known)
            Issue.record("the import should have failed")
        } catch SettingsBackupError.writeFailed {
        }

        #expect(box.text("appState.json", in: box.target)?.contains("3") == true)
        #expect(box.text("general.json", in: box.target)?.contains("false") == true)
        #expect(box.text("Images/a.png", in: box.target) == "old")
        #expect(!FileManager.default.fileExists(atPath: box.target.appending(path: "Images/z").path))
        #expect(box.backupFolders(in: box.target).count == 1)
    }

    @Test func importCreatesAMissingDirectory() async throws {
        let box = try Sandbox()
        let fresh = box.root.appending(path: "fresh", directoryHint: .isDirectory)
        try box.writeEnvelope(#"{"format":1,"app":"sTools","createdAt":"x","documents":{"appState":{"version":1,"value":{}}},"images":{"p/q.png":"AQID"}}"#)
        let report = try await SettingsBackup(directory: fresh).importSettings(from: box.file, knownVersions: known)
        #expect(report.backupURL == nil)
        #expect(box.text("appState.json", in: fresh) != nil)
        #expect(box.text("Images/p/q.png", in: fresh) != nil)
    }
}
