import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Custom Cursor's own files in the support folder (spec 5.7.1): `Cursor/applied`, there while sTools' pointer is
/// registered, and `Cursor/Originals/`, macOS's arrow as it was before, to put back. A registered pointer outlives
/// sTools, so the marker is how the next launch knows to restore it after a crash or a force quit.
struct CursorFiles {
    let folder: URL

    init(supportDirectory: URL) {
        folder = supportDirectory.appending(path: "Cursor", directoryHint: .isDirectory)
    }

    private var markerURL: URL { folder.appending(path: "applied", directoryHint: .notDirectory) }
    private var originalsURL: URL { folder.appending(path: "Originals", directoryHint: .isDirectory) }
    private var listURL: URL { originalsURL.appending(path: "cursors.json", directoryHint: .notDirectory) }

    // MARK: The marker

    var hasMarker: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    func writeMarker() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("sTools registered its own pointer.\n".utf8).write(to: markerURL, options: .atomic)
    }

    func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    // MARK: The originals

    /// One saved cursor: what `cursors.json` lists, with its images in `<name>-<index>.png` beside it.
    private struct Entry: Codable {
        var name: String
        var width, height, hotSpotX, hotSpotY: Double
        var frameCount: Int
        var frameDuration: Double
        var imageCount: Int
    }

    /// Replaces the saved copy with `cursors`, as PNGs and a list of their sizes and click points.
    func saveOriginals(_ cursors: [RegisteredCursor]) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: originalsURL.path) { try fileManager.removeItem(at: originalsURL) }
        try fileManager.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        var entries: [Entry] = []
        for cursor in cursors {
            for (index, image) in cursor.images.enumerated() {
                let url = originalsURL.appending(path: "\(cursor.name)-\(index).png") as CFURL
                guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            }
            entries.append(Entry(name: cursor.name, width: cursor.size.width, height: cursor.size.height,
                                 hotSpotX: cursor.hotSpot.x, hotSpotY: cursor.hotSpot.y, frameCount: cursor.frameCount,
                                 frameDuration: cursor.frameDuration, imageCount: cursor.images.count))
        }
        try JSONEncoder().encode(entries).write(to: listURL, options: .atomic)
    }

    /// The saved copy, leaving out any cursor whose images can't all be read; empty when there's none.
    func loadOriginals() -> [RegisteredCursor] {
        guard let data = try? Data(contentsOf: listURL), let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries.compactMap { entry in
            let images = (0..<entry.imageCount).compactMap { index -> CGImage? in
                let url = originalsURL.appending(path: "\(entry.name)-\(index).png") as CFURL
                guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            guard !images.isEmpty, images.count == entry.imageCount else { return nil }
            return RegisteredCursor(name: entry.name, size: CGSize(width: entry.width, height: entry.height),
                                    hotSpot: CGPoint(x: entry.hotSpotX, y: entry.hotSpotY), frameCount: entry.frameCount,
                                    frameDuration: entry.frameDuration, images: images)
        }
    }
}
