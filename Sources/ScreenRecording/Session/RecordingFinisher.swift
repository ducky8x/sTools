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

    /// `base.ext` in `folder`, or `base 2.ext`, `base 3.ext`… when taken. `ignoring` counts as free.
    public static func uniqueURL(base: String, fileExtension: String, in folder: URL, ignoring: URL? = nil) -> URL {
        var candidate = folder.appending(path: "\(base).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate.standardizedFileURL != ignoring?.standardizedFileURL {
            candidate = folder.appending(path: "\(base) \(number).\(fileExtension)")
            number += 1
        }
        return candidate
    }

    /// Saves recorded `.mov` files under `name` (or keeps their date-and-time name when it is nil or empty).
    /// With `.mp4`, each file is rewrapped without re-encoding and the `.mov` removed; a file that can't be
    /// rewrapped is kept as `.mov` and reported.
    public static func save(_ files: [URL], name: String?, as fileType: RecordingFileType) async -> SaveResult {
        var saved: [URL] = []
        var problems: [String] = []
        let chosen = name.flatMap(sanitizedName)
        for (index, file) in files.enumerated() {
            let folder = file.deletingLastPathComponent()
            let base: String
            if let chosen {
                base = index == 0 ? chosen : "\(chosen) part \(index + 1)"
            } else {
                base = file.deletingPathExtension().lastPathComponent
            }
            switch fileType {
            case .mov:
                saved.append(rename(file, to: uniqueURL(base: base, fileExtension: "mov", in: folder, ignoring: file), problems: &problems))
            case .mp4:
                let destination = uniqueURL(base: base, fileExtension: "mp4", in: folder)
                do {
                    try await Rewrapper.rewrap(from: file, to: destination)
                    try? FileManager.default.removeItem(at: file)
                    saved.append(destination)
                } catch {
                    problems.append("\(base) was kept as .mov because it couldn\u{2019}t be turned into .mp4 (\(error.localizedDescription)).")
                    saved.append(rename(file, to: uniqueURL(base: base, fileExtension: "mov", in: folder, ignoring: file), problems: &problems))
                }
            }
        }
        return SaveResult(files: saved, problems: problems)
    }

    /// Removes the recorded files.
    public static func delete(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

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
