import Foundation
@testable import KeyRebinder

/// A fresh directory under the system temporary directory, removed when the test ends.
struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "stools-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

func withTempDirectory<T>(_ body: (TempDirectory) async throws -> T) async throws -> T {
    let directory = try TempDirectory()
    defer { directory.remove() }
    return try await body(directory)
}

/// A clock that moves forward one second each time it is read.
final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_792_067_445.123)) {
        current = start
    }

    func now() -> Date {
        lock.withLock {
            defer { current = current.addingTimeInterval(1) }
            return current
        }
    }
}

/// Passes everything to the local file system, except that the next `corruptions` writes to `targetName`
/// are replaced by broken JSON.
final class FaultyFileSystem: KarabinerFileSystem, @unchecked Sendable {
    private let base = LocalKarabinerFileSystem()
    private let lock = NSLock()
    private var corruptionsLeft: Int
    private let targetName: String

    init(corruptions: Int, targetName: String = "karabiner.json") {
        corruptionsLeft = corruptions
        self.targetName = targetName
    }

    private func shouldCorrupt(_ url: URL) -> Bool {
        lock.withLock {
            guard url.lastPathComponent == targetName, corruptionsLeft > 0 else { return false }
            corruptionsLeft -= 1
            return true
        }
    }

    func read(_ url: URL) throws -> Data { try base.read(url) }
    func stat(_ url: URL) -> KarabinerFileStat? { base.stat(url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        try base.writeAtomically(shouldCorrupt(url) ? Data("{ \"profiles\": [".utf8) : data, to: url)
    }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func contentsOfDirectory(_ url: URL) throws -> [String] { try base.contentsOfDirectory(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
}

/// A temp directory holding a `karabiner.json` and a backups directory path, plus a store over them.
struct StoreRig {
    let directory: TempDirectory
    let configURL: URL
    let backupsURL: URL
    let store: KarabinerConfigStore

    /// - Parameter text: the starting file; `nil` leaves no file.
    init(
        _ directory: TempDirectory, text: String?, backupsKept: Int = 20,
        fileSystem: any KarabinerFileSystem = LocalKarabinerFileSystem(),
        clock: TickingClock = TickingClock()
    ) throws {
        self.directory = directory
        configURL = directory.url.appending(path: "config/karabiner.json")
        backupsURL = directory.url.appending(path: "backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text { try Data(text.utf8).write(to: configURL) }
        store = KarabinerConfigStore(
            configURL: configURL, backupsDirectory: backupsURL, now: { clock.now() },
            backupsKept: backupsKept, fileSystem: fileSystem
        )
    }

    var configText: String { (try? String(contentsOf: configURL, encoding: .utf8)) ?? "" }

    func backupNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backupsURL.path)) ?? []).sorted()
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    /// The fixture as Karabiner itself would lay it out.
    static func karabinerFormatted(_ fixture: String) throws -> String {
        try JSONValue.parse(FixtureLoader.text(fixture)).serialized()
    }
}

/// An edit that sets a top-level `counter` member.
func settingCounter(_ value: Int) -> @Sendable (JSONValue) throws -> JSONValue {
    { $0.setting("counter", .int(value)) }
}

/// An edit that adds one Simple Modification to the first profile.
let addingTabRebind: @Sendable (JSONValue) throws -> JSONValue = { root in
    let rebind: JSONValue = ["from": ["key_code": "tab"], "to": [["key_code": "escape"]]]
    let profile = root["profiles"]?[index: 0] ?? .emptyObject
    let updated = profile.updating("simple_modifications") { ($0 ?? .emptyArray).appending(rebind) }
    return root.updating("profiles") { $0?.replacing(at: 0, with: updated) }
}
