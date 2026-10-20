import Foundation

/// Why a read or a write of `karabiner.json` did not happen (or was undone).
public enum KarabinerStoreError: Error, Equatable, Sendable {
    /// There is no `karabiner.json`: Karabiner-Elements has not been set up for this user.
    case notSetUp(URL)
    /// `karabiner.json` is a symbolic link, which Karabiner does not watch, so sTools will not write through it.
    case symbolicLink(URL)
    /// The file exists but could not be read.
    case unreadable(URL, reason: String)
    /// The file is not valid JSON, or its top level is not an object.
    case malformed(reason: String)
    /// `apply` was called before `load`.
    case notLoaded
    /// The backup could not be made, so nothing was written.
    case backupFailed(reason: String)
    /// The new file could not be written; the old file is untouched.
    case writeFailed(reason: String)
    /// The written file did not read back as intended; the previous contents were restored.
    case verificationFailed(reason: String)
    /// The written file did not read back as intended and the previous contents could not be restored;
    /// the backup at `backup` holds them.
    case restoreFailed(reason: String, backup: URL)
}

extension KarabinerStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSetUp:
            "Karabiner-Elements has not been set up yet: there is no karabiner.json. Open Karabiner-Elements once, then try again."
        case .symbolicLink:
            "karabiner.json is a symbolic link. Karabiner-Elements does not reload a linked file, so sTools will not change it."
        case .unreadable(_, let reason):
            "sTools could not read karabiner.json: \(reason)"
        case .malformed(let reason):
            "karabiner.json is not valid: \(reason)"
        case .notLoaded:
            "The Karabiner settings have not been loaded yet."
        case .backupFailed(let reason):
            "sTools could not back up karabiner.json, so nothing was changed: \(reason)"
        case .writeFailed(let reason):
            "sTools could not write karabiner.json; the file was not changed: \(reason)"
        case .verificationFailed(let reason):
            "The saved karabiner.json did not read back correctly, so the previous version was put back: \(reason)"
        case .restoreFailed(let reason, let backup):
            "The saved karabiner.json did not read back correctly and the previous version could not be put back (\(reason)). A copy is at \(backup.path)."
        }
    }
}

/// The outcome of ``KarabinerConfigStore/apply(confirm:_:)``.
public enum ApplyResult: Equatable, Sendable {
    /// The edit was written. `backupURL` is the copy of the file as it was just before.
    case written(config: KarabinerConfig, backupURL: URL)
    /// The edit changed nothing, so nothing was written. `config` is what is on disk now.
    case unchanged(config: KarabinerConfig)
    /// `karabiner.json` changed on disk since it was loaded. Nothing was written. `preview` is the freshly
    /// loaded file with the same edit applied; show it, and call `apply(confirm: true, …)` to write it.
    case changedExternally(preview: KarabinerConfig)
}
