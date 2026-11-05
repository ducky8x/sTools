import CoreGraphics
import Foundation
import Testing
@testable import STPlatform

/// Applying and restoring sTools' pointer, with its marker and macOS's saved arrow (spec 5.7.1), over a fake swapper: no
/// test changes the real pointer.
@MainActor
@Suite("The pointer swap")
struct PointerSwapTests {
    @Test func applyingShowsThePointerAndRestoringPutsTheArrowBack() {
        let swapper = FakeCursorSwapper()
        let swap = PointerSwap(swapper: swapper, supportDirectory: pointerTempDirectory())
        #expect(swap.isSupported)
        #expect(!swap.isApplied)

        #expect(swap.apply(makeCursor()))
        #expect(swap.isApplied)
        #expect(swapper.applyCount == 1)
        #expect(swapper.current[CursorNames.arrow[2]]?.size == CGSize(width: 12, height: 12), "all three names")

        swap.restore()
        #expect(!swap.isApplied)
        #expect(swapper.restoreCount == 1)
        // What macOS had before goes back: its two arrows.
        #expect(swapper.restored.last?.map(\.name).sorted() == Array(CursorNames.arrow.prefix(2)).sorted())
        swap.restore()
        #expect(swapper.restoreCount == 1, "nothing left to restore")
    }

    @Test func theMarkerIsWrittenBeforeApplyingAndRemovedAfterRestoring() {
        let directory = pointerTempDirectory()
        let files = CursorFiles(supportDirectory: directory)
        let swapper = FakeCursorSwapper()
        var markerDuringApply: Bool?
        var markerDuringRestore: Bool?
        swapper.duringApply = { markerDuringApply = files.hasMarker }
        swapper.duringRestore = { markerDuringRestore = files.hasMarker }
        let swap = PointerSwap(swapper: swapper, supportDirectory: directory)

        swap.apply(makeCursor())
        #expect(markerDuringApply == true)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Cursor/applied").path))
        swap.restore()
        #expect(markerDuringRestore == true)
        #expect(!files.hasMarker)
    }

    /// The originals are read and saved only on the way from nothing applied to applied: a re-apply never copies sTools'
    /// own pointer as the original.
    @Test func theOriginalsAreSavedOnlyWhileNothingIsApplied() {
        let directory = pointerTempDirectory()
        let files = CursorFiles(supportDirectory: directory)
        let swapper = FakeCursorSwapper()
        let swap = PointerSwap(swapper: swapper, supportDirectory: directory)
        func reads() -> Int { swapper.calls.filter { if case .read = $0 { true } else { false } }.count }

        swap.apply(makeCursor())
        #expect(Array(swapper.calls.prefix(3)) == CursorNames.arrow.map { FakeCursorSwapper.Call.read($0) }, "read before the apply")
        #expect(swapper.calls.dropFirst(3).first == .apply)
        swap.apply(makeCursor())
        swap.apply(makeCursor())
        #expect(swapper.applyCount == 3)
        #expect(reads() == 3)
        #expect(files.loadOriginals().map(\.size) == [CGSize(width: 28, height: 40), CGSize(width: 28, height: 40)])

        swap.restore()
        #expect(swapper.restored.last?.allSatisfy { $0.size == CGSize(width: 28, height: 40) } == true)
        // Restored and applied again, it takes a fresh copy, of macOS's arrows again.
        swap.apply(makeCursor())
        #expect(reads() == 6)
        #expect(files.loadOriginals().map(\.size) == [CGSize(width: 28, height: 40), CGSize(width: 28, height: 40)])
        swap.restore()
    }

    /// A marker left by a crash or a force quit: the arrow that was saved goes back as the swap is made, at launch.
    @Test func aLeftoverMarkerRestoresAtOnce() throws {
        let directory = pointerTempDirectory()
        let files = CursorFiles(supportDirectory: directory)
        try files.saveOriginals([RegisteredCursor.systemArrow(name: CursorNames.arrow[0])])
        try files.writeMarker()
        let swapper = FakeCursorSwapper()

        let swap = PointerSwap(swapper: swapper, supportDirectory: directory)
        #expect(swapper.calls == [.restore])
        #expect(swapper.restored.first?.map(\.name) == [CursorNames.arrow[0]])
        #expect(!files.hasMarker)
        #expect(!swap.isApplied)
    }

    @Test func withoutAMarkerMakingItChangesNothing() throws {
        let directory = pointerTempDirectory()
        try CursorFiles(supportDirectory: directory).saveOriginals([RegisteredCursor.systemArrow(name: CursorNames.arrow[0])])
        let swapper = FakeCursorSwapper()
        _ = PointerSwap(swapper: swapper, supportDirectory: directory)
        #expect(swapper.calls.isEmpty)
    }

    /// Without a marker on disk the pointer couldn't be put back after a crash, so nothing is applied.
    @Test func whenTheMarkerCantBeWrittenNothingIsApplied() throws {
        let directory = pointerTempDirectory()
        // A file where the Cursor folder goes.
        try Data().write(to: directory.appending(path: "Cursor"))
        let swapper = FakeCursorSwapper()
        let swap = PointerSwap(swapper: swapper, supportDirectory: directory)
        #expect(!swap.apply(makeCursor()))
        #expect(swapper.applyCount == 0)
        #expect(!swap.isApplied)
    }

    /// A restore puts back the copy taken at the first apply, even when the file on disk changed since.
    @Test func restoringUsesTheCopyFromTheFirstApply() throws {
        let directory = pointerTempDirectory()
        let swapper = FakeCursorSwapper()
        let swap = PointerSwap(swapper: swapper, supportDirectory: directory)
        swap.apply(makeCursor())
        try CursorFiles(supportDirectory: directory).saveOriginals([RegisteredCursor.systemArrow(name: CursorNames.arrow[1])])
        swap.restore()
        #expect(swapper.restored.last?.map(\.name).sorted() == Array(CursorNames.arrow.prefix(2)).sorted())
    }

    /// Without the calls nothing is applied, and a marker a run left stays, since nothing here can put that pointer back.
    @Test func withoutTheCallsNothingChanges() throws {
        let directory = pointerTempDirectory()
        let files = CursorFiles(supportDirectory: directory)
        try files.writeMarker()
        let swapper = FakeCursorSwapper(isSupported: false)
        let swap = PointerSwap(swapper: swapper, supportDirectory: directory)
        #expect(!swap.isSupported)
        #expect(!swap.apply(makeCursor()))
        swap.restore()
        #expect(swapper.calls.isEmpty)
        #expect(files.hasMarker)
    }
}
