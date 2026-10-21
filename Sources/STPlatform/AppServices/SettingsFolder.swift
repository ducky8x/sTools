import Foundation

/// Names shared by everything that reads or writes the settings directory.
public enum SettingsLayout {
    /// Subfolder of the settings directory that holds user images referenced by settings.
    public static let imagesFolderName = "Images"
    /// Subfolder that holds the owner's own sound files, Timer Overlay's alarm sounds, all directly inside it.
    public static let soundsFolderName = "Sounds"
    /// Subfolder that receives timestamped copies of the settings before an import or a reset.
    public static let backupsFolderName = "Backups"
    /// File extension of an exported settings file.
    public static let exportFileExtension = "stools-settings"

    /// Document names become file names, so they are limited to letters, digits, `_` and `-`.
    static func isValidDocumentName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64
            && name.unicodeScalars.allSatisfy { scalar in
                (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"))
            }
    }

    /// An image path relative to the Images folder: `/`-separated, no empty, `.` or `..` components.
    static func isValidImagePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// A file name directly inside the Sounds folder, checked like an image path but flat: one visible name
    /// (not hidden), never a path, and short enough for the file system.
    public static func isValidSoundFileName(_ name: String) -> Bool {
        isValidImagePath(name) && !name.contains("/") && !name.hasPrefix(".") && name.utf8.count <= 255
    }
}

/// File-system helpers over one settings directory.
struct SettingsFolder: Sendable {
    let url: URL

    var imagesURL: URL { url.appending(path: SettingsLayout.imagesFolderName, directoryHint: .isDirectory) }
    var soundsURL: URL { url.appending(path: SettingsLayout.soundsFolderName, directoryHint: .isDirectory) }

    /// Everything in the directory except the Backups folder.
    func items() throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != SettingsLayout.backupsFolderName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Creates `Backups/<yyyyMMdd-HHmmss>-<label>` (adding `-2`, `-3`, … if taken).
    func makeBackupFolder(label: String, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backups = url.appending(path: SettingsLayout.backupsFolderName, directoryHint: .isDirectory)
        let stem = "\(formatter.string(from: now))-\(label)"
        var candidate = backups.appending(path: stem, directoryHint: .isDirectory)
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = backups.appending(path: "\(stem)-\(attempt)", directoryHint: .isDirectory)
            attempt += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    /// Copies every item into a new backup folder. Returns nil when the directory has nothing to copy.
    func copyToBackup(label: String, now: Date) throws -> URL? {
        let items = try items()
        guard !items.isEmpty else { return nil }
        let backup = try makeBackupFolder(label: label, now: now)
        do {
            for item in items {
                try FileManager.default.copyItem(at: item, to: backup.appending(path: item.lastPathComponent))
            }
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
        return backup
    }
}
