import Foundation
import Testing
@testable import STPlatform

private struct Prefs: SettingsDocument {
    static let name = "prefs"
    static let version = 1
    static let defaultValue = Prefs(title: "default", count: 0)
    var title: String
    var count: Int
}

private struct Other: SettingsDocument {
    static let name = "other"
    static let version = 1
    static let defaultValue = Other(flag: false)
    var flag: Bool
}

/// Version 3 of a document whose v1 stored `a` and whose v2 renamed it to `alpha`.
private struct Chain: SettingsDocument {
    static let name = "chain"
    static let version = 3
    static let defaultValue = Chain(alpha: "none", beta: 0)
    var alpha: String
    var beta: Int

    static func migrate(from oldVersion: Int, _ raw: [String: Any]) throws -> [String: Any] {
        var raw = raw
        switch oldVersion {
        case 1:
            raw["alpha"] = raw.removeValue(forKey: "a")
        case 2:
            raw["beta"] = (raw["alpha"] as? String)?.count ?? -1
        default:
            break
        }
        return raw
    }
}

private struct Failing: SettingsDocument {
    struct MigrationFailure: Error {}
    static let name = "failing"
    static let version = 2
    static let defaultValue = Failing(value: "default")
    var value: String

    static func migrate(from oldVersion: Int, _ raw: [String: Any]) throws -> [String: Any] {
        throw MigrationFailure()
    }
}

/// Version 2 adds an optional key; the default `migrate` keeps old files readable.
private struct Additive: SettingsDocument {
    static let name = "additive"
    static let version = 2
    static let defaultValue = Additive(old: "", added: nil)
    var old: String
    var added: Int?
}

private struct Big: SettingsDocument {
    static let name = "big"
    static let version = 1
    static let defaultValue = Big(items: [])
    var items: [String]
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sTools-settings-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func withTempDirectory(_ body: @MainActor (URL) async throws -> Void) async throws {
    let directory = try makeTempDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try await body(directory)
}

private func fileNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private func write(_ text: String, to name: String, in directory: URL) throws {
    try Data(text.utf8).write(to: directory.appending(path: name))
}

private func modificationDate(of url: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

@MainActor
@Suite struct SettingsStoreTests {
    // MARK: Basics

    @Test func roundTripsThroughANewStoreInstance() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: "hello", count: 7))
            await store.flush()

            let reloaded = SettingsStore(directory: directory).load(Prefs.self)
            #expect(reloaded == Prefs(title: "hello", count: 7))
        }
    }

    @Test func missingFileYieldsDefaultAndCreatesNothing() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            #expect(store.load(Prefs.self) == Prefs.defaultValue)
            #expect(try fileNames(in: directory).isEmpty)
        }
    }

    @Test func fileIsVersionedEnvelopeWithSortedKeysAndIndentation() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: "x", count: 2))
            await store.flush()

            let text = try String(contentsOf: directory.appending(path: "prefs.json"), encoding: .utf8)
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(object["version"] as? Int == 1)
            let value = try #require(object["value"] as? [String: Any])
            #expect(value["title"] as? String == "x")
            #expect(text.contains("\n  "))
            let countIndex = try #require(text.range(of: "\"count\""))
            let titleIndex = try #require(text.range(of: "\"title\""))
            #expect(countIndex.lowerBound < titleIndex.lowerBound)
        }
    }

    @Test func directoryIsCreatedOnDemand() async throws {
        try await withTempDirectory { root throws in
            let nested = root.appending(path: "a/b/c", directoryHint: .isDirectory)
            let store = SettingsStore(directory: nested)
            store.save(Prefs(title: "deep", count: 1))
            await store.flush()
            #expect(try fileNames(in: nested) == ["prefs.json"])
        }
    }

    @Test func twoDocumentTypesDoNotCollide() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: "p", count: 3))
            store.save(Other(flag: true))
            await store.flush()

            #expect(try fileNames(in: directory) == ["other.json", "prefs.json"])
            let reloaded = SettingsStore(directory: directory)
            #expect(reloaded.load(Prefs.self) == Prefs(title: "p", count: 3))
            #expect(reloaded.load(Other.self) == Other(flag: true))
        }
    }

    @Test func loadReturnsAValueSavedButNotYetWritten() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory, debounce: .seconds(60))
            store.save(Prefs(title: "pending", count: 9))
            #expect(store.load(Prefs.self) == Prefs(title: "pending", count: 9))
            #expect(try fileNames(in: directory).isEmpty)
            await store.flush()
        }
    }

    @Test func unicodeSurvivesARoundTrip() async throws {
        try await withTempDirectory { directory throws in
            let title = "héllo wörld — 日本語 العربية 🧭🏳️‍🌈 e\u{301} \"quoted\" back\\slash /slash\nnewline\ttab"
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: title, count: -1))
            await store.flush()
            #expect(SettingsStore(directory: directory).load(Prefs.self).title == title)
        }
    }

    @Test func largeDocumentRoundTrips() async throws {
        try await withTempDirectory { directory throws in
            let items = (0..<20_000).map { "item-\($0)-日本語-🧭" }
            let store = SettingsStore(directory: directory)
            store.save(Big(items: items))
            await store.flush()
            #expect(SettingsStore(directory: directory).load(Big.self).items == items)
        }
    }

    @Test func defaultDirectoryIsApplicationSupportSTools() {
        let path = SettingsStore.defaultDirectory().path
        #expect(path.hasSuffix("Application Support/sTools"))
    }

    // MARK: Corruption

    @Test(arguments: [
        ("garbage bytes", "\u{1}\u{2}not json at all \u{7f}"),
        ("truncated JSON", "{\"version\": 1, \"value\": {\"title\": \"cut o"),
        ("wrong types", "{\"version\": 1, \"value\": {\"title\": 5, \"count\": \"many\"}}"),
        ("empty file", ""),
        ("valid JSON, not the envelope", "{\"title\": \"bare\", \"count\": 1}"),
        ("top-level array", "[1, 2, 3]"),
        ("value is not an object", "{\"version\": 1, \"value\": 5}"),
        ("version is not a number", "{\"version\": \"one\", \"value\": {\"title\": \"t\", \"count\": 1}}"),
        ("version below 1", "{\"version\": 0, \"value\": {\"title\": \"t\", \"count\": 1}}"),
    ])
    func corruptFileIsMovedAsideAndDefaultReturned(label: String, contents: String) async throws {
        try await withTempDirectory { directory throws in
            try write(contents, to: "prefs.json", in: directory)
            let store = SettingsStore(directory: directory)

            #expect(store.load(Prefs.self) == Prefs.defaultValue, "\(label)")

            let names = try fileNames(in: directory)
            #expect(names.count == 1, "\(label)")
            let aside = try #require(names.first)
            #expect(aside.hasPrefix("prefs.corrupt-") && aside.hasSuffix(".json"), "\(label)")
            let kept = try String(contentsOf: directory.appending(path: aside), encoding: .utf8)
            #expect(kept == contents, "\(label)")
        }
    }

    @Test func repeatedCorruptionKeepsEveryAsideFile() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            for attempt in 1...3 {
                try write("broken \(attempt)", to: "prefs.json", in: directory)
                #expect(store.load(Prefs.self) == Prefs.defaultValue)
            }
            #expect(try fileNames(in: directory).count == 3)
        }
    }

    @Test func savingAfterCorruptionStartsFreshAndKeepsTheAsideFile() async throws {
        try await withTempDirectory { directory throws in
            try write("garbage", to: "prefs.json", in: directory)
            let store = SettingsStore(directory: directory)
            _ = store.load(Prefs.self)
            store.save(Prefs(title: "fresh", count: 1))
            await store.flush()

            #expect(try fileNames(in: directory).count == 2)
            #expect(SettingsStore(directory: directory).load(Prefs.self) == Prefs(title: "fresh", count: 1))
        }
    }

    // MARK: Versions and migration

    @Test func newerVersionIsMovedAsideAndNeverOverwritten() async throws {
        try await withTempDirectory { directory throws in
            let future = "{\"version\": 9, \"value\": {\"title\": \"from the future\", \"count\": 1}}"
            try write(future, to: "prefs.json", in: directory)
            let store = SettingsStore(directory: directory)

            #expect(store.load(Prefs.self) == Prefs.defaultValue)
            #expect(try fileNames(in: directory) == ["prefs.newer-v9.json"])

            store.save(Prefs(title: "mine", count: 2))
            await store.flush()
            #expect(try fileNames(in: directory) == ["prefs.json", "prefs.newer-v9.json"])
            let kept = try String(contentsOf: directory.appending(path: "prefs.newer-v9.json"), encoding: .utf8)
            #expect(kept == future)
        }
    }

    @Test func secondNewerFileOfTheSameVersionDoesNotOverwriteTheFirst() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            try write("{\"version\": 4, \"value\": {\"title\": \"one\", \"count\": 1}}", to: "prefs.json", in: directory)
            _ = store.load(Prefs.self)
            try write("{\"version\": 4, \"value\": {\"title\": \"two\", \"count\": 2}}", to: "prefs.json", in: directory)
            _ = store.load(Prefs.self)

            #expect(try fileNames(in: directory) == ["prefs.newer-v4-2.json", "prefs.newer-v4.json"])
        }
    }

    @Test func migrationChainRunsStepByStep() async throws {
        try await withTempDirectory { directory throws in
            try write("{\"version\": 1, \"value\": {\"a\": \"hello\"}}", to: "chain.json", in: directory)
            let store = SettingsStore(directory: directory)
            #expect(store.load(Chain.self) == Chain(alpha: "hello", beta: 5))
            #expect(try fileNames(in: directory) == ["chain.json"])
        }
    }

    @Test func migrationFromTheMiddleOfTheChainOnlyRunsLaterSteps() async throws {
        try await withTempDirectory { directory throws in
            try write("{\"version\": 2, \"value\": {\"alpha\": \"abc\"}}", to: "chain.json", in: directory)
            let store = SettingsStore(directory: directory)
            #expect(store.load(Chain.self) == Chain(alpha: "abc", beta: 3))
        }
    }

    @Test func currentVersionSkipsMigration() async throws {
        try await withTempDirectory { directory throws in
            try write("{\"version\": 3, \"value\": {\"alpha\": \"x\", \"beta\": 42}}", to: "chain.json", in: directory)
            let store = SettingsStore(directory: directory)
            #expect(store.load(Chain.self) == Chain(alpha: "x", beta: 42))
        }
    }

    @Test func savingAMigratedDocumentWritesTheCurrentVersion() async throws {
        try await withTempDirectory { directory throws in
            try write("{\"version\": 1, \"value\": {\"a\": \"hey\"}}", to: "chain.json", in: directory)
            let store = SettingsStore(directory: directory)
            store.save(store.load(Chain.self))
            await store.flush()

            let data = try Data(contentsOf: directory.appending(path: "chain.json"))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["version"] as? Int == 3)
        }
    }

    @Test func throwingMigrationIsTreatedAsCorruption() async throws {
        try await withTempDirectory { directory throws in
            let old = "{\"version\": 1, \"value\": {\"value\": \"old\"}}"
            try write(old, to: "failing.json", in: directory)
            let store = SettingsStore(directory: directory)

            #expect(store.load(Failing.self) == Failing.defaultValue)
            let names = try fileNames(in: directory)
            #expect(names.count == 1 && names[0].hasPrefix("failing.corrupt-"))
            #expect(try String(contentsOf: directory.appending(path: names[0]), encoding: .utf8) == old)
        }
    }

    @Test func defaultMigrationKeepsAdditiveChanges() async throws {
        try await withTempDirectory { directory throws in
            try write("{\"version\": 1, \"value\": {\"old\": \"kept\"}}", to: "additive.json", in: directory)
            let store = SettingsStore(directory: directory)
            #expect(store.load(Additive.self) == Additive(old: "kept", added: nil))
        }
    }

    /// What a document that writes its upgrade back reads: the file's version, never a guess, and nothing while a save
    /// waits (that save writes the current version).
    @Test func storedVersionReadsTheFilesVersion() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory, debounce: .seconds(60))
            #expect(store.storedVersion(Chain.self) == nil, "no file")
            try write("{\"version\": 1, \"value\": {\"a\": \"hey\"}}", to: "chain.json", in: directory)
            #expect(store.storedVersion(Chain.self) == 1)
            _ = store.load(Chain.self)
            #expect(store.storedVersion(Chain.self) == 1, "loading alone writes nothing")

            store.save(store.load(Chain.self))
            #expect(store.storedVersion(Chain.self) == nil, "a save is waiting")
            await store.flush()
            #expect(store.storedVersion(Chain.self) == 3)

            try write("not json", to: "chain.json", in: directory)
            #expect(store.storedVersion(Chain.self) == nil)
        }
    }

    // MARK: Debounce, flush, atomicity

    @Test func rapidSavesCoalesceIntoOneWriteOfTheLatestValue() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory, debounce: .milliseconds(40))
            for count in 1...10 { store.save(Prefs(title: "v", count: count)) }
            #expect(try fileNames(in: directory).isEmpty)

            for _ in 0..<500 where store.writeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(150))

            #expect(store.writeCount == 1)
            #expect(SettingsStore(directory: directory).load(Prefs.self).count == 10)
        }
    }

    @Test func eachSaveRestartsTheDebounceWindow() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory, debounce: .milliseconds(200))
            store.save(Prefs(title: "a", count: 1))
            try await Task.sleep(for: .milliseconds(120))
            store.save(Prefs(title: "a", count: 2))
            try await Task.sleep(for: .milliseconds(120))
            #expect(store.writeCount == 0)
            await store.flush()
        }
    }

    @Test func flushWritesImmediatelyAndPendingTimersDoNotWriteAgain() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory, debounce: .milliseconds(40))
            store.save(Prefs(title: "now", count: 1))
            store.save(Other(flag: true))
            await store.flush()

            #expect(try fileNames(in: directory) == ["other.json", "prefs.json"])
            #expect(store.writeCount == 2)
            try await Task.sleep(for: .milliseconds(150))
            #expect(store.writeCount == 2)
        }
    }

    @Test func flushWithNothingPendingIsANoOp() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            await store.flush()
            #expect(try fileNames(in: directory).isEmpty)
        }
    }

    @Test func atomicWritesLeaveNoTemporaryFiles() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            for count in 1...25 {
                store.save(Prefs(title: "round", count: count))
                store.save(Other(flag: count.isMultiple(of: 2)))
                await store.flush()
            }
            #expect(try fileNames(in: directory) == ["other.json", "prefs.json"])
        }
    }

    @Test func savingTheValueAlreadyOnDiskDoesNotRewriteTheFile() async throws {
        try await withTempDirectory { directory throws in
            let url = directory.appending(path: "prefs.json")
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: "same", count: 1))
            await store.flush()
            #expect(store.writeCount == 1)

            let past = Date(timeIntervalSince1970: 1_000_000_000)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)

            store.save(Prefs(title: "same", count: 1))
            await store.flush()
            #expect(store.writeCount == 1)
            #expect(try modificationDate(of: url) == past)

            store.save(Prefs(title: "changed", count: 1))
            await store.flush()
            #expect(store.writeCount == 2)
            #expect(try modificationDate(of: url) > past)
        }
    }

    @Test func aFreshStoreAlsoSkipsRewritingIdenticalContent() async throws {
        try await withTempDirectory { directory throws in
            let first = SettingsStore(directory: directory)
            first.save(Prefs(title: "same", count: 1))
            await first.flush()

            let second = SettingsStore(directory: directory)
            second.save(Prefs(title: "same", count: 1))
            await second.flush()
            #expect(second.writeCount == 0)
        }
    }

    // MARK: Failure handling

    @Test func unwritableDirectoryIsLoggedAndTheNextSaveRecovers() async throws {
        try await withTempDirectory { directory throws in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            let store = SettingsStore(directory: directory)

            store.save(Prefs(title: "blocked", count: 1))
            await store.flush()
            #expect(store.failedWriteCount == 1)
            #expect(store.writeCount == 0)
            #expect(try fileNames(in: directory).isEmpty)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            store.save(Prefs(title: "recovered", count: 2))
            await store.flush()
            #expect(store.writeCount == 1)
            #expect(SettingsStore(directory: directory).load(Prefs.self) == Prefs(title: "recovered", count: 2))
        }
    }

    @Test func failedWriteIsRetriedByTheNextFlushEvenWithoutANewSave() async throws {
        try await withTempDirectory { directory throws in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: "kept in memory", count: 5))
            await store.flush()
            #expect(store.failedWriteCount == 1)
            #expect(store.load(Prefs.self) == Prefs(title: "kept in memory", count: 5))

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            await store.flush()
            #expect(SettingsStore(directory: directory).load(Prefs.self) == Prefs(title: "kept in memory", count: 5))
        }
    }

    @Test func debouncedWriteToAnUnwritableDirectoryDoesNotCrash() async throws {
        try await withTempDirectory { directory throws in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            let store = SettingsStore(directory: directory, debounce: .milliseconds(20))
            store.save(Prefs(title: "blocked", count: 1))
            for _ in 0..<500 where store.failedWriteCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(store.failedWriteCount == 1)
        }
    }

    @Test func directoryPathBlockedByARegularFileIsLoggedNotFatal() async throws {
        try await withTempDirectory { root throws in
            let blocker = root.appending(path: "blocker")
            try Data("file".utf8).write(to: blocker)
            let store = SettingsStore(directory: blocker.appending(path: "settings", directoryHint: .isDirectory))
            store.save(Prefs(title: "x", count: 1))
            await store.flush()
            #expect(store.failedWriteCount == 1)
            #expect(store.load(Prefs.self) == Prefs(title: "x", count: 1))
        }
    }

    @Test func readOnlyDirectoryStillLoadsAValidFile() async throws {
        try await withTempDirectory { directory throws in
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: "locked", count: 4))
            await store.flush()

            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            #expect(SettingsStore(directory: directory).load(Prefs.self) == Prefs(title: "locked", count: 4))
        }
    }

    @Test func readOnlyDirectoryWithCorruptFileReturnsDefaultAndKeepsTheFile() async throws {
        try await withTempDirectory { directory throws in
            try write("garbage", to: "prefs.json", in: directory)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

            let store = SettingsStore(directory: directory)
            #expect(store.load(Prefs.self) == Prefs.defaultValue)
            #expect(try fileNames(in: directory) == ["prefs.json"])
        }
    }

    @Test func unreadableFileIsNotMovedAside() async throws {
        try await withTempDirectory { directory throws in
            let url = directory.appending(path: "prefs.json")
            let store = SettingsStore(directory: directory)
            store.save(Prefs(title: "secret", count: 1))
            await store.flush()
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

            #expect(SettingsStore(directory: directory).load(Prefs.self) == Prefs.defaultValue)
            #expect(try fileNames(in: directory) == ["prefs.json"])
        }
    }
}
