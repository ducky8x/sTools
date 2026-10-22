import Foundation

/// Free names for recording files (spec 5.4.4). A recording never takes a name that's already in its folder: a start,
/// a split part and every save or rename pick the next free one, `base 2`, `base 3`, as Finder does, so no file that
/// was there is ever replaced and nothing fails because the date-and-time name of the same second is taken.
///
/// A name is held by a recording as a whole: `base.mov` or `base.mp4`, or any of its split parts, `base part 2.mov`
/// and on. So a new recording never shares a name with an earlier one, whatever was kept of it, and all its parts
/// keep the one name: `base 2.mov`, `base 2 part 2.mov`.
enum RecordingNames {
    /// The file types a recording is kept as.
    static let fileExtensions = ["mov", "mp4"]

    /// The name of part `index` (from 1) of the recording named `base`: `base`, then `base part 2`, `base part 3`…
    static func partName(_ base: String, index: Int) -> String {
        index <= 1 ? base : "\(base) part \(index)"
    }

    /// `base`, or `base 2`, `base 3`… : the first name no recording in `folder` holds, `own` (the files being named,
    /// in that folder) aside.
    static func freeBase(_ base: String, in folder: URL, own: [URL] = []) -> String {
        let taken = takenBases(in: folder, own: own)
        var candidate = base
        var number = 2
        while taken.contains(key(candidate)) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    /// `name.ext` in `folder`, or `name 2.ext`, `name 3.ext`… when that's there; `own` counts as free. The last check
    /// before a file is written or moved, for a name that turned up after `freeBase` chose.
    static func freeURL(_ name: String, fileExtension: String, in folder: URL, own: URL? = nil) -> URL {
        var candidate = folder.appending(path: "\(name).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path), !same(candidate, own) {
            candidate = folder.appending(path: "\(name) \(number).\(fileExtension)")
            number += 1
        }
        return candidate
    }

    /// The names recordings in `folder` hold, compared without case (macOS' usual volumes ignore it).
    private static func takenBases(in folder: URL, own: [URL]) -> Set<String> {
        let ownNames = Set(own.map { key($0.lastPathComponent) })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var taken: Set<String> = []
        for name in names where !ownNames.contains(key(name)) {
            let file = name as NSString
            guard fileExtensions.contains(file.pathExtension.lowercased()) else { continue }
            let stem = file.deletingPathExtension
            taken.insert(key(stem))
            if let base = baseOfPart(stem) { taken.insert(key(base)) }
        }
        return taken
    }

    /// `base` for a `base part N` name, else nil.
    private static func baseOfPart(_ stem: String) -> String? {
        guard let range = stem.range(of: " part ", options: .backwards) else { return nil }
        let number = stem[range.upperBound...]
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), (Int(number) ?? 0) >= 2 else { return nil }
        return String(stem[..<range.lowerBound])
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func same(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        return key(a.standardizedFileURL.path) == key(b.standardizedFileURL.path)
    }
}
