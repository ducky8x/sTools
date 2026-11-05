import CoreGraphics
import Foundation
import Testing
@testable import CustomCursor

/// `Cursor/applied` and `Cursor/Originals/` in the support folder (spec 5.7.1), here in a temporary one.
@Suite("Custom Cursor: its files")
struct CursorFilesTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sTools-cursor-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func theMarkerIsWrittenAndRemoved() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CursorFiles(supportDirectory: root)
        #expect(files.folder == root.appending(path: "Cursor", directoryHint: .isDirectory))
        #expect(!files.hasMarker)
        try files.writeMarker()
        #expect(files.hasMarker)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Cursor/applied").path))
        files.removeMarker()
        #expect(!files.hasMarker)
    }

    /// The originals keep each name's size, click point, frames and every image, as macOS had them.
    @Test func theOriginalsComeBackAsTheyWereSaved() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CursorFiles(supportDirectory: root)
        let arrow = RegisteredCursor.systemArrow(name: CursorNames.arrow[0])
        let arrowS = RegisteredCursor.systemArrow(name: CursorNames.arrow[1])
        try files.saveOriginals([arrow, arrowS])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Cursor/Originals/cursors.json").path))

        let loaded = files.loadOriginals()
        #expect(loaded.map(\.name) == [arrow.name, arrowS.name])
        let first = try #require(loaded.first)
        #expect(first.size == CGSize(width: 28, height: 40))
        #expect(first.hotSpot == CGPoint(x: 5, y: 5))
        #expect(first.frameCount == 1)
        #expect(first.frameDuration == 0)
        #expect(first.images.map(\.width) == arrow.images.map(\.width))
        #expect(first.images.map(\.height) == arrow.images.map(\.height))
    }

    /// A new copy replaces the old one whole, so a name that's gone isn't put back from an earlier copy.
    @Test func savingAgainReplacesTheLastCopy() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CursorFiles(supportDirectory: root)
        try files.saveOriginals(CursorNames.arrow.map { RegisteredCursor.systemArrow(name: $0) })
        try files.saveOriginals([RegisteredCursor.systemArrow(name: CursorNames.arrow[0])])
        #expect(files.loadOriginals().map(\.name) == [CursorNames.arrow[0]])
    }

    @Test func noCopyReadsAsNone() {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CursorFiles(supportDirectory: root).loadOriginals().isEmpty)
    }

    /// The three names macOS draws its arrow by on macOS 26 and later.
    @Test func theArrowsNames() {
        #expect(CursorNames.arrow == ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowS", "com.apple.cursor.0"])
    }
}

extension RegisteredCursor {
    /// A stand-in for macOS 27's arrow: 28 × 40 points, clicking at 5, 5, with four images.
    static func systemArrow(name: String) -> RegisteredCursor {
        RegisteredCursor(name: name, size: CGSize(width: 28, height: 40), hotSpot: CGPoint(x: 5, y: 5), frameCount: 1, frameDuration: 0,
                         images: [1, 2, 3, 4].map { makeImage(width: 28 * $0, height: 40 * $0) })
    }
}
