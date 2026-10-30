import CryptoKit
import Foundation

/// Reads and edits `karabiner.json` with the write-safety steps of spec 5.5.3: order-preserving edits,
/// change detection, a rotating backup, an atomic write, a symbolic-link refusal and automatic restore.
public actor KarabinerConfigStore {
    public nonisolated let configURL: URL
    public nonisolated let backupsDirectory: URL

    private let fileSystem: any KarabinerFileSystem
    private let backups: KarabinerBackups

    /// The digest of what was on disk at the last `load()` or successful write. Only the digest is kept: an edit always
    /// runs on a fresh read, and the parsed tree and the bytes would be a second copy of the file in memory for as long
    /// as the app runs.
    private var loadedDigest: Data?
    /// Digest of the on-disk content whose `.changedExternally` preview was shown; only a confirmed call
    /// that still finds exactly this content may write over an external change.
    private var previewedDigest: Data?

    /// `~/.config/karabiner/karabiner.json`.
    public static func defaultConfigURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: ".config/karabiner/karabiner.json", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/sTools/Karabiner Backups`.
    public static func defaultBackupsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "sTools/Karabiner Backups", directoryHint: .isDirectory)
    }

    /// - Parameter backupsKept: how many backups to keep (newest first); 20 per the spec.
    public init(
        configURL: URL = KarabinerConfigStore.defaultConfigURL(),
        backupsDirectory: URL = KarabinerConfigStore.defaultBackupsDirectory(),
        now: @escaping @Sendable () -> Date = { Date() },
        backupsKept: Int = 20
    ) {
        self.init(
            configURL: configURL, backupsDirectory: backupsDirectory, now: now,
            backupsKept: backupsKept, fileSystem: LocalKarabinerFileSystem()
        )
    }

    init(
        configURL: URL, backupsDirectory: URL, now: @escaping @Sendable () -> Date,
        backupsKept: Int, fileSystem: any KarabinerFileSystem
    ) {
        self.configURL = configURL
        self.backupsDirectory = backupsDirectory
        self.fileSystem = fileSystem
        backups = KarabinerBackups(directory: backupsDirectory, keep: backupsKept, now: now, fileSystem: fileSystem)
    }

    /// Reads the file and remembers its content as the base for later change detection.
    /// A symbolic link is read (so the diagram works) but never written.
    public func load() throws -> KarabinerConfig {
        let disk = try readDisk()
        loadedDigest = disk.digest
        previewedDigest = nil
        return disk.config
    }

    /// Applies one edit to the file and writes it, following the write-safety steps.
    ///
    /// The edit always runs on a fresh parse of the file on disk, so it must be a pure function of its input.
    /// When the file changed since `load()` (or the last write), nothing is written and
    /// ``ApplyResult/changedExternally(preview:)`` carries the edited fresh file; call again with
    /// `confirm: true` to write exactly that, which only works if the file is still the one previewed.
    public func apply(
        confirm: Bool = false,
        _ edit: @Sendable (JSONValue) throws -> JSONValue
    ) throws -> ApplyResult {
        guard let loadedDigest else { throw KarabinerStoreError.notLoaded }
        if fileSystem.stat(configURL)?.isSymbolicLink == true {
            throw KarabinerStoreError.symbolicLink(configURL)
        }
        let disk = try readDisk()
        let edited = try edit(disk.root)

        if edited == disk.root {
            self.loadedDigest = disk.digest
            previewedDigest = nil
            return .unchanged(config: disk.config)
        }
        if disk.digest != loadedDigest, !(confirm && previewedDigest == disk.digest) {
            previewedDigest = disk.digest
            return .changedExternally(preview: KarabinerConfig(root: edited))
        }
        return try write(edited, replacing: disk)
    }

    // MARK: Reading

    /// One read of the file, held only while a call uses it.
    private struct Snapshot {
        var root: JSONValue
        var digest: Data
        var containsComments: Bool
        /// The exact bytes read, kept for the backup and a possible restore.
        var data: Data

        var config: KarabinerConfig { KarabinerConfig(root: root, containsComments: containsComments) }
    }

    private static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func readDisk() throws -> Snapshot {
        guard fileSystem.stat(configURL) != nil else { throw KarabinerStoreError.notSetUp(configURL) }
        let data: Data
        do {
            data = try fileSystem.read(configURL)
        } catch {
            throw KarabinerStoreError.unreadable(configURL, reason: error.localizedDescription)
        }
        let root: JSONValue
        do {
            root = try JSONValue.parse(data: data)
        } catch {
            throw KarabinerStoreError.malformed(reason: "\(error)")
        }
        guard root.isObject else { throw KarabinerStoreError.malformed(reason: "the top level is not an object") }
        let comments = String(data: data, encoding: .utf8).map(JSONValue.containsComments) ?? false
        return Snapshot(root: root, digest: Self.digest(of: data), containsComments: comments, data: data)
    }

    // MARK: Writing

    private func write(_ edited: JSONValue, replacing disk: Snapshot) throws -> ApplyResult {
        let backupURL: URL
        do {
            backupURL = try backups.create(from: disk.data)
        } catch {
            throw KarabinerStoreError.backupFailed(reason: error.localizedDescription)
        }

        do {
            try fileSystem.writeAtomically(Data(edited.serialized().utf8), to: configURL)
        } catch {
            backups.discard(backupURL)
            throw KarabinerStoreError.writeFailed(reason: error.localizedDescription)
        }

        let written: Data
        do {
            written = try fileSystem.read(configURL)
            guard try JSONValue.parse(data: written) == edited else { throw ReadBackMismatch() }
        } catch {
            throw restore(disk, backupURL: backupURL, reason: Self.describe(error))
        }

        backups.prune()
        loadedDigest = Self.digest(of: written)
        previewedDigest = nil
        return .written(config: KarabinerConfig(root: edited), backupURL: backupURL)
    }

    private struct ReadBackMismatch: Error {}

    private static func describe(_ error: any Error) -> String {
        switch error {
        case is ReadBackMismatch: "the file differs from what was written"
        case let parseError as JSONParseError: "\(parseError)"
        default: error.localizedDescription
        }
    }

    /// Puts the previous bytes back and returns the error to throw.
    private func restore(_ disk: Snapshot, backupURL: URL, reason: String) -> KarabinerStoreError {
        do {
            try fileSystem.writeAtomically(disk.data, to: configURL)
            guard try fileSystem.read(configURL) == disk.data else {
                return .restoreFailed(reason: reason, backup: backupURL)
            }
        } catch {
            return .restoreFailed(reason: reason, backup: backupURL)
        }
        loadedDigest = disk.digest
        previewedDigest = nil
        return .verificationFailed(reason: reason)
    }
}
