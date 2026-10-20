import Foundation
import OSLog

public enum ResetError: Error, Equatable, LocalizedError {
    /// `reset(confirmed:)` was called without the user's confirmation.
    case notConfirmed
    /// The backup folder could not be created; nothing was changed.
    case backupFailed(String)
    /// A file could not be moved; everything already moved was put back.
    case moveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfirmed: "The reset was not confirmed."
        case .backupFailed(let reason): "sTools could not back up your settings first, so nothing was changed: \(reason)"
        case .moveFailed(let reason): "The reset could not finish, so your settings were kept: \(reason)"
        }
    }
}

/// "Reset sTools…": moves every settings document and user image into `Backups/<timestamp>-reset`.
///
/// Afterwards the settings directory holds only `Backups`, so every document loads its default value —
/// including `AppState`, whose `prologueCompleted` is false again, which makes the Prologue run next.
/// Settings objects the running app still holds in memory are not touched; the app should relaunch
/// (or reload every document) and must not save them again.
public struct ResetService: Sendable {
    private let folder: SettingsFolder
    private let flush: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private let log = STLog.logger("ResetService")

    /// - Parameters:
    ///   - directory: the directory the `SettingsStore` uses.
    ///   - store: when given, pending debounced writes are flushed first so they end up in the backup.
    ///   - now: clock for the backup folder name.
    @MainActor
    public init(directory: URL, store: SettingsStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        folder = SettingsFolder(url: directory)
        flush = { await store?.flush() }
        self.now = now
    }

    /// Wipes the settings after the caller has confirmed with the user.
    /// - Returns: the backup folder, or nil when there was nothing to reset.
    @discardableResult
    public func reset(confirmed: Bool) async throws -> URL? {
        guard confirmed else { throw ResetError.notConfirmed }
        await flush()
        let items = try folder.items()
        guard !items.isEmpty else { return nil }

        let backup: URL
        do {
            backup = try folder.makeBackupFolder(label: "reset", now: now())
        } catch {
            throw ResetError.backupFailed(error.localizedDescription)
        }

        let fileManager = FileManager.default
        var moved: [(from: URL, to: URL)] = []
        do {
            for item in items {
                let destination = backup.appending(path: item.lastPathComponent)
                try fileManager.moveItem(at: item, to: destination)
                moved.append((item, destination))
            }
        } catch {
            log.error("Reset failed, putting settings back: \(error.localizedDescription, privacy: .public)")
            for entry in moved.reversed() { try? fileManager.moveItem(at: entry.to, to: entry.from) }
            try? fileManager.removeItem(at: backup)
            throw ResetError.moveFailed(error.localizedDescription)
        }
        return backup
    }
}
