import Foundation
import OSLog

/// Why a settings file could not be imported at all. Nothing is changed when one of these is thrown
/// (a `writeFailed` error is thrown only after the previous settings have been restored).
public enum SettingsBackupError: Error, Equatable, LocalizedError {
    case unreadable(String)
    /// The file is not a sTools settings export (not JSON, or the envelope is incomplete).
    case notABackup
    /// The file was written by something other than sTools.
    case foreignApp(String)
    /// The file uses a newer envelope format than this version of sTools understands.
    case newerFormat(Int)
    case backupFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "The file could not be read: \(reason)"
        case .notABackup: "This is not a sTools settings file."
        case .foreignApp: "This settings file was not made by sTools."
        case .newerFormat: "This settings file was made by a newer version of sTools. Update sTools and try again."
        case .backupFailed(let reason): "sTools could not back up your current settings first, so nothing was changed: \(reason)"
        case .writeFailed(let reason): "The settings could not be written, so your previous settings were kept: \(reason)"
        }
    }
}

/// Exports every settings document into one `.stools-settings` file and imports such a file back.
///
/// File format (format 1): one JSON object
///
///     {"format": 1, "app": "sTools", "createdAt": "<ISO 8601>",
///      "documents": {"<name>": {"version": N, "value": {...}}},
///      "images": {"<path relative to Images/>": "<base64>"},
///      "sounds": {"<file name in Sounds/>": "<base64>"}}
///
/// Images and the owner's sounds (Timer Overlay's alarm files) are embedded as base64 text inside the same
/// JSON file: one file, no archive code, trivially inspectable. The cost is a third more bytes than a zip
/// would use, which is fine for the handful of backdrop and crosshair images and alarm sounds a user keeps.
/// `sounds` is optional, so files written before it still import, and builds from before it ignore it.
///
/// Importing never deletes anything: documents, images and sounds absent from the file stay as they are.
/// The current directory is copied into `Backups/<timestamp>-before-import` first, and any write failure
/// restores the previous files from that copy.
public struct SettingsBackup: Sendable {
    /// Envelope format this version reads and writes.
    public static let formatVersion = 1
    /// Value of the envelope's `app` key.
    public static let appID = "sTools"

    /// Why one document, image or sound was not applied.
    public enum SkipReason: Equatable, Sendable, CustomStringConvertible {
        /// The name is not a valid document name, image path or sound file name (possible path traversal).
        case invalidName
        /// The entry is malformed (missing version or value, version below 1, bad base64).
        case invalidEntry
        /// No document of that name is known to this version of sTools.
        case unknownDocument
        /// The document was written by a newer version of sTools than the one running.
        case newerVersion(found: Int, supported: Int)

        public var description: String {
            switch self {
            case .invalidName: "invalid name"
            case .invalidEntry: "malformed entry"
            case .unknownDocument: "unknown document"
            case .newerVersion(let found, let supported): "made by a newer version (v\(found), this version reads up to v\(supported))"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case applied
        case skipped(SkipReason)
    }

    /// The result for one document, image or sound, keyed by document name, image path or sound file name.
    public struct ItemResult: Equatable, Sendable {
        public let name: String
        public let outcome: Outcome
        public init(name: String, outcome: Outcome) {
            self.name = name
            self.outcome = outcome
        }
    }

    public struct ExportSummary: Equatable, Sendable {
        public let documentNames: [String]
        public let imageCount: Int
        /// The owner's sound files carried, from `Sounds/`.
        public let soundCount: Int
    }

    public struct ImportReport: Equatable, Sendable {
        /// One entry per document in the file, sorted by name.
        public let documents: [ItemResult]
        /// One entry per image in the file, sorted by path.
        public let images: [ItemResult]
        /// One entry per sound in the file, sorted by file name.
        public let sounds: [ItemResult]
        /// The `Backups/...` folder holding the settings as they were before the import, nil when there was nothing to back up.
        public let backupURL: URL?

        /// Documents, images and sounds applied: Settings' "Imported 3 items".
        public var appliedCount: Int { (documents + images + sounds).filter { $0.outcome == .applied }.count }
        public var skippedCount: Int { (documents + images + sounds).count - appliedCount }
    }

    private let folder: SettingsFolder
    private let flush: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private let log = STLog.logger("SettingsBackup")

    /// - Parameters:
    ///   - directory: the directory the `SettingsStore` uses.
    ///   - store: when given, pending debounced writes are flushed before an export and an import.
    ///   - now: clock for `createdAt` and backup folder names.
    @MainActor
    public init(directory: URL, store: SettingsStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        folder = SettingsFolder(url: directory)
        flush = { await store?.flush() }
        self.now = now
    }

    // MARK: Export

    /// Writes all documents (and Images and Sounds) to `url` atomically.
    /// Files that are not valid document envelopes (moved-aside corrupt files, stray files) are left out.
    @discardableResult
    public func export(to url: URL) async throws -> ExportSummary {
        await flush()
        var documents: [String: Any] = [:]
        for item in try folder.items() where item.pathExtension == "json" {
            let name = item.deletingPathExtension().lastPathComponent
            guard SettingsLayout.isValidDocumentName(name),
                let data = try? Data(contentsOf: item),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let version = root["version"] as? Int, version >= 1,
                let value = root["value"] as? [String: Any]
            else {
                log.notice("Skipping \(item.lastPathComponent, privacy: .public) in export: not a settings document")
                continue
            }
            documents[name] = ["version": version, "value": value]
        }

        var images: [String: String] = [:]
        for (path, imageURL) in imageFiles() {
            images[path] = try Data(contentsOf: imageURL).base64EncodedString()
        }

        var sounds: [String: String] = [:]
        for (name, soundURL) in soundFiles() {
            sounds[name] = try Data(contentsOf: soundURL).base64EncodedString()
        }

        let envelope: [String: Any] = [
            "format": Self.formatVersion,
            "app": Self.appID,
            "createdAt": now().formatted(.iso8601),
            "documents": documents,
            "images": images,
            "sounds": sounds,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return ExportSummary(documentNames: documents.keys.sorted(), imageCount: images.count, soundCount: sounds.count)
    }

    /// Regular files directly inside Sounds/, as (file name, URL), sorted by name. The folder is flat: anything in a
    /// subfolder, hidden, or with a name an import would refuse is left out.
    private func soundFiles() -> [(String, URL)] {
        let root = folder.soundsURL
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .map { ($0.lastPathComponent, $0) }
            .filter { SettingsLayout.isValidSoundFileName($0.0) }
            .sorted { $0.0 < $1.0 }
    }

    /// Regular files under Images/, as (relative path, URL), sorted by path.
    private func imageFiles() -> [(String, URL)] {
        let root = folder.imagesURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        let rootComponents = root.standardizedFileURL.pathComponents
        var result: [(String, URL)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
            result.append((relative, url))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    // MARK: Import

    /// Validates the file at `url` and applies what it can.
    /// - Parameter knownVersions: current version of every document this build knows, by name. Documents of
    ///   unknown names, or with a version above the known one, are skipped; older versions are written as-is
    ///   and migrated by `SettingsStore` when loaded.
    /// - Returns: per-document, per-image and per-sound results. Throws `SettingsBackupError` when the file as a
    ///   whole is unusable or the write failed (previous settings restored).
    public func importSettings(from url: URL, knownVersions: [String: Int]) async throws -> ImportReport {
        await flush()
        let plan = try Plan(parsing: readFile(url), knownVersions: knownVersions)
        guard !plan.documentWrites.isEmpty || !plan.imageWrites.isEmpty || !plan.soundWrites.isEmpty else {
            return ImportReport(
                documents: plan.documentResults, images: plan.imageResults, sounds: plan.soundResults, backupURL: nil)
        }

        let backup: URL?
        do {
            backup = try folder.copyToBackup(label: "before-import", now: now())
        } catch {
            throw SettingsBackupError.backupFailed(error.localizedDescription)
        }

        var targets: [(url: URL, data: Data)] = plan.documentWrites.map {
            (folder.url.appending(path: "\($0.name).json", directoryHint: .notDirectory), $0.data)
        }
        targets += plan.imageWrites.map {
            (folder.imagesURL.appending(path: $0.path, directoryHint: .notDirectory), $0.data)
        }
        targets += plan.soundWrites.map {
            (folder.soundsURL.appending(path: $0.name, directoryHint: .notDirectory), $0.data)
        }

        var touched: [URL] = []
        var createdDirectories: [URL] = []
        do {
            for target in targets {
                createdDirectories += try createMissingDirectories(for: target.url.deletingLastPathComponent())
                touched.append(target.url)
                try target.data.write(to: target.url, options: .atomic)
            }
        } catch {
            log.error("Import failed, restoring previous settings: \(error.localizedDescription, privacy: .public)")
            restore(touched: touched, createdDirectories: createdDirectories, from: backup)
            throw SettingsBackupError.writeFailed(error.localizedDescription)
        }
        return ImportReport(
            documents: plan.documentResults, images: plan.imageResults, sounds: plan.soundResults, backupURL: backup)
    }

    private func readFile(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SettingsBackupError.unreadable(error.localizedDescription)
        }
    }

    /// Creates `directory` and any missing parents inside the settings directory, returning what it created (deepest first).
    private func createMissingDirectories(for directory: URL) throws -> [URL] {
        var missing: [URL] = []
        var current = directory
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: current.path), current.path.count > 1 {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        if !missing.isEmpty { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        return missing
    }

    /// Puts every touched file back as it was in `backup`, deletes files that did not exist, removes created directories.
    private func restore(touched: [URL], createdDirectories: [URL], from backup: URL?) {
        let fileManager = FileManager.default
        let rootComponents = folder.url.standardizedFileURL.pathComponents.count
        for url in touched {
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootComponents).joined(separator: "/")
            try? fileManager.removeItem(at: url)
            guard let backup else { continue }
            let original = backup.appending(path: relative)
            if fileManager.fileExists(atPath: original.path) {
                try? fileManager.copyItem(at: original, to: url)
            }
        }
        for directory in createdDirectories { try? fileManager.removeItem(at: directory) }
    }

    /// The validated content of an envelope: what to write and what was skipped.
    private struct Plan {
        var documentResults: [ItemResult] = []
        var imageResults: [ItemResult] = []
        var soundResults: [ItemResult] = []
        var documentWrites: [(name: String, data: Data)] = []
        var imageWrites: [(path: String, data: Data)] = []
        var soundWrites: [(name: String, data: Data)] = []

        init(parsing data: Data, knownVersions: [String: Int]) throws {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SettingsBackupError.notABackup
            }
            guard let app = root["app"] as? String else { throw SettingsBackupError.notABackup }
            guard app == SettingsBackup.appID else { throw SettingsBackupError.foreignApp(app) }
            guard let format = root["format"] as? Int, format >= 1 else { throw SettingsBackupError.notABackup }
            if format > SettingsBackup.formatVersion { throw SettingsBackupError.newerFormat(format) }
            guard let documents = root["documents"] as? [String: Any] else { throw SettingsBackupError.notABackup }
            let images = root["images"] as? [String: Any] ?? [:]
            let sounds = root["sounds"] as? [String: Any] ?? [:]

            for name in documents.keys.sorted() {
                let outcome = Self.evaluate(name: name, entry: documents[name], knownVersions: knownVersions) { data in
                    documentWrites.append((name, data))
                }
                documentResults.append(ItemResult(name: name, outcome: outcome))
            }
            for path in images.keys.sorted() {
                let outcome = Self.evaluateFile(entry: images[path], nameIsValid: SettingsLayout.isValidImagePath(path)) { data in
                    imageWrites.append((path, data))
                }
                imageResults.append(ItemResult(name: path, outcome: outcome))
            }
            for name in sounds.keys.sorted() {
                let outcome = Self.evaluateFile(entry: sounds[name], nameIsValid: SettingsLayout.isValidSoundFileName(name)) { data in
                    soundWrites.append((name, data))
                }
                soundResults.append(ItemResult(name: name, outcome: outcome))
            }
        }

        private static func evaluate(
            name: String, entry: Any?, knownVersions: [String: Int], accept: (Data) -> Void
        ) -> Outcome {
            guard SettingsLayout.isValidDocumentName(name) else { return .skipped(.invalidName) }
            guard let entry = entry as? [String: Any],
                let version = entry["version"] as? Int, version >= 1,
                let value = entry["value"] as? [String: Any]
            else { return .skipped(.invalidEntry) }
            guard let supported = knownVersions[name] else { return .skipped(.unknownDocument) }
            if version > supported { return .skipped(.newerVersion(found: version, supported: supported)) }
            let file: [String: Any] = ["version": version, "value": value]
            guard let data = try? JSONSerialization.data(
                withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            else { return .skipped(.invalidEntry) }
            accept(data)
            return .applied
        }

        /// An image or a sound: a checked name and base64 bytes.
        private static func evaluateFile(entry: Any?, nameIsValid: Bool, accept: (Data) -> Void) -> Outcome {
            guard nameIsValid else { return .skipped(.invalidName) }
            guard let text = entry as? String, let data = Data(base64Encoded: text) else { return .skipped(.invalidEntry) }
            accept(data)
            return .applied
        }
    }
}
