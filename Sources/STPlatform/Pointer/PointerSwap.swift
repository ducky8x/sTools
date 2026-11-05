import Foundation

/// Shows sTools' own pointer in place of macOS's arrow, and puts the arrow back (spec 5.7.1). It keeps the files that
/// make the swap safe: before the first apply it saves macOS's arrow in `Cursor/Originals/` and writes the
/// `Cursor/applied` marker, and after the restore it removes the marker. A swapped pointer outlives sTools, so a marker
/// found as this starts means the last run crashed or was force quit with sTools' pointer up: it's restored at once.
///
/// The app builds one, before anything else, over the live swapper; tests build one over a fake.
@MainActor
public final class PointerSwap {
    private let swapper: any CursorSwapping
    let files: CursorFiles
    /// macOS's arrow as it was when sTools' was applied, to put back.
    private var originals: [RegisteredCursor] = []
    private let log = STLog.logger("Pointer")

    /// Whether sTools' pointer is registered with macOS right now.
    public private(set) var isApplied = false

    /// Restores a pointer the last run left applied, if its marker is there. The files live in `supportDirectory`, the
    /// settings store's folder, so a test's store keeps them in its temporary folder.
    public init(swapper: any CursorSwapping, supportDirectory: URL) {
        self.swapper = swapper
        files = CursorFiles(supportDirectory: supportDirectory)
        // A marker on a macOS without the calls stays: nothing here can put that pointer back.
        if swapper.isSupported, files.hasMarker {
            log.notice("Found the pointer applied by the last run; restoring it")
            swapper.restore(files.loadOriginals())
            files.removeMarker()
        }
    }

    /// Whether this macOS has every call the swap needs.
    public var isSupported: Bool { swapper.isSupported }

    /// Shows `cursor` as the arrow. The first apply saves macOS's arrow and writes the marker; if either can't be written,
    /// nothing is applied, since the pointer couldn't be put back after a crash. Returns whether `cursor` is up.
    @discardableResult
    public func apply(_ cursor: CursorImage) -> Bool {
        guard isSupported else { return false }
        if !isApplied {
            // Read only while nothing of sTools' is registered, so the copy is always macOS's own (or another app's).
            let copies = CursorNames.arrow.compactMap(swapper.registered)
            do {
                try files.saveOriginals(copies)
                try files.writeMarker()
            } catch {
                log.error("Couldn't write the pointer's files, so it wasn't applied: \(error.localizedDescription, privacy: .public)")
                return false
            }
            originals = copies
        }
        swapper.apply(cursor, names: CursorNames.arrow)
        isApplied = true
        return true
    }

    /// Puts macOS's arrow back, if sTools' is up, and removes the marker.
    public func restore() {
        guard isApplied else { return }
        swapper.restore(originals.isEmpty ? files.loadOriginals() : originals)
        files.removeMarker()
        isApplied = false
        originals = []
    }
}
