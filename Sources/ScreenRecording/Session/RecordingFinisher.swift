import Foundation

/// The Save / Delete decision after a recording (spec 5.4.4). Recordings are always written as `.mov` first,
/// named by date and time, so a crash leaves a findable file; Save renames and, for `.mp4`, rewraps.
public enum RecordingFinisher {
    public struct SaveResult: Equatable, Sendable {
        /// The files as saved, in recording order.
        public var files: [URL]
        /// One sentence per file that could not be saved as asked (it is kept as .mov instead).
        public var problems: [String]
    }

    /// `2026-10-13 21.04.37`: the name of a recording nobody named.
    public static func dateName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// A typed name made safe for a file name: slashes and colons become dashes, surrounding spaces and leading
    /// dots go. Nil when nothing is left.
    public static func sanitizedName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(200))
    }

    /// Where `save` puts `files` under `name` (or their date-and-time name when it is nil or empty), in recording
    /// order: the name, or the next free one when a recording in the folder holds it (`base 2`, as Finder does), every
    /// split part with it (`base 2 part 2`). Files already under the name they'd get stay where they are.
    public static func plannedFiles(for files: [URL], name: String?, as fileType: RecordingFileType) -> [URL] {
        guard let first = files.first else { return [] }
        let folder = first.deletingLastPathComponent()
        let wanted = name.flatMap(sanitizedName) ?? first.deletingPathExtension().lastPathComponent
        let base = RecordingNames.freeBase(wanted, in: folder, own: files)
        return files.indices.map {
            folder.appending(path: "\(RecordingNames.partName(base, index: $0 + 1)).\(fileType.fileExtension)")
        }
    }

    /// Saves recorded `.mov` files under `name` (or keeps their date-and-time name when it is nil or empty), at
    /// `plannedFiles`, so no file that's there is ever replaced. With `.mp4`, each file is rewrapped without
    /// re-encoding and the `.mov` removed; a file that can't be rewrapped is kept as `.mov` and reported.
    public static func save(_ files: [URL], name: String?, as fileType: RecordingFileType) async -> SaveResult {
        var saved: [URL] = []
        var problems: [String] = []
        for (file, planned) in zip(files, plannedFiles(for: files, name: name, as: fileType)) {
            let folder = planned.deletingLastPathComponent()
            let base = planned.deletingPathExtension().lastPathComponent
            switch fileType {
            case .mov:
                saved.append(rename(file, to: RecordingNames.freeURL(base, fileExtension: "mov", in: folder, own: file), problems: &problems))
            case .mp4:
                let destination = RecordingNames.freeURL(base, fileExtension: "mp4", in: folder)
                do {
                    try await Rewrapper.rewrap(from: file, to: destination)
                    try? FileManager.default.removeItem(at: file)
                    saved.append(destination)
                } catch {
                    problems.append("\(base) was kept as .mov because it couldn\u{2019}t be turned into .mp4 (\(error.localizedDescription)).")
                    saved.append(rename(file, to: RecordingNames.freeURL(base, fileExtension: "mov", in: folder, own: file), problems: &problems))
                }
            }
        }
        return SaveResult(files: saved, problems: problems)
    }

    /// Removes the recorded files.
    public static func delete(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Moves `file` to `destination`, which `freeURL` found free: moving never replaces a file, so one that turned up
    /// there since is left alone and `file` stays where it is.
    private static func rename(_ file: URL, to destination: URL, problems: inout [String]) -> URL {
        guard destination.standardizedFileURL != file.standardizedFileURL else { return file }
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        } catch {
            problems.append("\(file.lastPathComponent) couldn\u{2019}t be renamed (\(error.localizedDescription)); it is still there.")
            return file
        }
    }
}
