import Foundation
import OSLog

/// Persists `SettingsDocument` values as versioned JSON files with debounced, atomic writes.
///
/// File shape: `{"version": N, "value": {...}}`, pretty-printed with sorted keys.
/// Loading never throws: unusable files are moved aside (never deleted) and the
/// document's default value is returned. Call `flush()` before the app quits so
/// pending writes reach disk.
@MainActor
public final class SettingsStore {
    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let value: Value
    }

    private enum Rejection: Error {
        case notAnEnvelope
        case newer(version: Int)
        case invalidMigrationResult
    }

    /// The directory this store reads and writes — what `SettingsBackup`/`ResetService` need to work
    /// on the same files, whichever directory this instance was actually given (not necessarily
    /// `defaultDirectory()`, e.g. in tests).
    public let directory: URL
    private let debounce: Duration
    private let log = STLog.logger("SettingsStore")

    /// Encoded envelopes waiting for their debounce timer, keyed by document name.
    private var pending: [String: Data] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    /// Number of file writes that completed successfully.
    private(set) var writeCount = 0
    /// Number of file writes that failed and were logged.
    private(set) var failedWriteCount = 0

    public init(directory: URL, debounce: Duration = .milliseconds(500)) {
        self.directory = directory
        self.debounce = debounce
    }

    /// `~/Library/Application Support/sTools`.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "sTools", directoryHint: .isDirectory)
    }

    /// Returns the stored value, or `D.defaultValue` when the file is missing or unusable.
    /// A value saved but not yet written is returned as-is.
    public func load<D: SettingsDocument>(_ type: D.Type) -> D {
        if let data = pending[D.name], let envelope = try? Self.decoder.decode(Envelope<D>.self, from: data) {
            return envelope.value
        }
        let url = fileURL(D.name)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return D.defaultValue
        } catch {
            log.error("Cannot read \(D.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return D.defaultValue
        }
        do {
            return try Self.decode(D.self, from: data)
        } catch Rejection.newer(let version) {
            log.error("\(D.name, privacy: .public) was written by a newer version (\(version)); moving it aside")
            moveAside(url, label: "newer-v\(version)")
        } catch {
            log.error("\(D.name, privacy: .public) is unusable (\(String(describing: error), privacy: .public)); moving it aside")
            moveAside(url, label: "corrupt-\(Self.timestamp())")
        }
        return D.defaultValue
    }

    /// The version the document's file on disk was written with. Nil when there is no file with a version (missing,
    /// unreadable, moved aside), or while a save waits to be written. For a document that writes its upgraded value
    /// back once it has loaded, so its migration runs once.
    public func storedVersion<D: SettingsDocument>(_ type: D.Type) -> Int? {
        guard pending[D.name] == nil, let data = try? Data(contentsOf: fileURL(D.name)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["version"] as? Int
    }

    /// Queues `value` for writing. Rapid saves of the same document coalesce into one write
    /// of the latest value, `debounce` after the last save.
    public func save<D: SettingsDocument>(_ value: D) {
        let name = D.name
        let data: Data
        do {
            data = try Self.encoder.encode(Envelope(version: D.version, value: value))
        } catch {
            log.error("Cannot encode \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        pending[name] = data
        timers[name]?.cancel()
        let delay = debounce
        timers[name] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.timers[name] = nil
            self?.write(name)
        }
    }

    /// Writes everything pending immediately. A write that failed earlier is retried here.
    public func flush() async {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for name in pending.keys.sorted() { write(name) }
    }

    private func write(_ name: String) {
        guard let data = pending[name] else { return }
        let url = fileURL(name)
        if let existing = try? Data(contentsOf: url), existing == data {
            pending[name] = nil
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            pending[name] = nil
            writeCount += 1
        } catch {
            failedWriteCount += 1
            log.error("Cannot write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL(_ name: String) -> URL {
        directory.appending(path: "\(name).json", directoryHint: .notDirectory)
    }

    /// Renames `url` to `<stem>.<label>.json` (adding `-2`, `-3`, … if taken) so nothing is ever overwritten.
    private func moveAside(_ url: URL, label: String) {
        let stem = url.deletingPathExtension().lastPathComponent
        let fileManager = FileManager.default
        var candidate = directory.appending(path: "\(stem).\(label).json", directoryHint: .notDirectory)
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(stem).\(label)-\(attempt).json", directoryHint: .notDirectory)
            attempt += 1
        }
        do {
            try fileManager.moveItem(at: url, to: candidate)
        } catch {
            log.error("Cannot move \(url.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func decode<D: SettingsDocument>(_ type: D.Type, from data: Data) throws -> D {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int, version >= 1,
              var raw = root["value"] as? [String: Any]
        else { throw Rejection.notAnEnvelope }

        if version > D.version { throw Rejection.newer(version: version) }
        if version == D.version { return try decoder.decode(Envelope<D>.self, from: data).value }

        for step in version..<D.version { raw = try D.migrate(from: step, raw) }
        guard JSONSerialization.isValidJSONObject(raw) else { throw Rejection.invalidMigrationResult }
        return try decoder.decode(D.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        return formatter.string(from: Date())
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
