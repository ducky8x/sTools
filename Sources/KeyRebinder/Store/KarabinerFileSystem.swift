import Foundation

/// What the store needs to know about a path.
struct KarabinerFileStat: Equatable, Sendable {
    var isSymbolicLink: Bool
    var permissions: Int?
}

/// The file operations the config store and its backups use, so tests can inject faults.
protocol KarabinerFileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    /// Information about the item itself (a symbolic link is not followed); `nil` when nothing exists there.
    func stat(_ url: URL) -> KarabinerFileStat?
    /// Writes `data` to a temporary file next to `url`, then renames it over `url`. An existing file's
    /// permissions are kept. On failure `url` is untouched and no temporary file is left behind.
    func writeAtomically(_ data: Data, to url: URL) throws
    func createDirectory(_ url: URL) throws
    func contentsOfDirectory(_ url: URL) throws -> [String]
    func remove(_ url: URL) throws
}

struct LocalKarabinerFileSystem: KarabinerFileSystem {
    func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func stat(_ url: URL) -> KarabinerFileStat? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return KarabinerFileStat(
            isSymbolicLink: (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue
        )
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).stools-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            if let permissions = stat(url)?.permissions {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            if rename(temporary.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func contentsOfDirectory(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
