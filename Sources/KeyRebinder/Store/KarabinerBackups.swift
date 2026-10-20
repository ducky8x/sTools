import Foundation

/// Timestamped copies of `karabiner.json`, newest `keep` retained. Names look like
/// `karabiner-20261015-123045-123-01.json` (UTC time, then a counter for copies made in the same millisecond),
/// so a plain name sort is oldest-first.
struct KarabinerBackups: Sendable {
    let directory: URL
    let keep: Int
    let now: @Sendable () -> Date
    let fileSystem: any KarabinerFileSystem

    private static func isBackupName(_ name: String) -> Bool {
        name.wholeMatch(of: /karabiner-\d{8}-\d{6}-\d{3}-\d{2,}\.json/) != nil
    }

    /// Writes `data` as a new backup and returns its location.
    func create(from data: Data) throws -> URL {
        try fileSystem.createDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: now())
        var counter = 1
        var url: URL
        repeat {
            url = directory.appending(path: "karabiner-\(stamp)-\(String(format: "%02d", counter)).json")
            counter += 1
        } while fileSystem.stat(url) != nil
        try fileSystem.writeAtomically(data, to: url)
        return url
    }

    /// Deletes all but the newest `keep` backups. Failing to delete an old copy must not fail a save that
    /// already succeeded, so errors here are ignored; the next save prunes again.
    func prune() {
        guard let names = try? fileSystem.contentsOfDirectory(directory) else { return }
        let backups = names.filter(Self.isBackupName).sorted()
        for name in backups.dropLast(max(keep, 1)) {
            try? fileSystem.remove(directory.appending(path: name))
        }
    }

    /// Removes a backup made for a write that then failed, so failed attempts do not push real backups out.
    func discard(_ url: URL) {
        try? fileSystem.remove(url)
    }
}
