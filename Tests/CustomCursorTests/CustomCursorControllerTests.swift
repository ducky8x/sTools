import CoreGraphics
import Foundation
import STPlatform
import Testing
@testable import CustomCursor

/// When the pointer is applied and restored (spec 5.7.2), with a fake swapper: no test changes the real pointer.
@MainActor
@Suite("Custom Cursor: applying and restoring")
struct CustomCursorControllerTests {
    private func everywhere(_ controller: CustomCursorController) {
        controller.settings.where = .everywhere
    }

    // MARK: Switching

    @Test func switchingOnAppliesAndSwitchingOffRestores() {
        let directory = tempDirectory()
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        everywhere(controller)
        #expect(swapper.applyCount == 0)

        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(controller.isApplied)
        #expect(swapper.applyCount == 1)
        #expect(swapper.applied.last?.size == CGSize(width: 18, height: 18))
        #expect(swapper.current[CursorNames.arrow[2]]?.size == CGSize(width: 18, height: 18), "all three names")

        controller.setEnabled(false)
        #expect(!controller.isApplied)
        #expect(swapper.restoreCount == 1)
        // What macOS had before goes back: its two arrows.
        #expect(swapper.restored.last?.map(\.name).sorted() == Array(CursorNames.arrow.prefix(2)).sorted())
        #expect(swapper.restored.last?.allSatisfy { $0.size == CGSize(width: 28, height: 40) } == true)
    }

    @Test func switchingOnTwiceAppliesOnce() {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        controller.setEnabled(true)
        #expect(swapper.applyCount == 1)
        controller.setEnabled(false)
        controller.setEnabled(false)
        #expect(swapper.restoreCount == 1)
    }

    /// Nothing is applied while the tool is off, whatever changes.
    @Test func offItNeverSwaps() {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        everywhere(controller)
        controller.settings.size = 30
        controller.settings.shape = .plus
        #expect(swapper.calls.isEmpty)
    }

    // MARK: The marker and the originals

    @Test func theMarkerIsWrittenBeforeApplyingAndRemovedAfterRestoring() {
        let directory = tempDirectory()
        let files = CursorFiles(supportDirectory: directory)
        let swapper = FakeCursorSwapper()
        var markerDuringApply: Bool?
        var markerDuringRestore: Bool?
        swapper.duringApply = { markerDuringApply = files.hasMarker }
        swapper.duringRestore = { markerDuringRestore = files.hasMarker }
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        everywhere(controller)

        controller.setEnabled(true)
        #expect(markerDuringApply == true)
        #expect(files.hasMarker)
        controller.setEnabled(false)
        #expect(markerDuringRestore == true)
        #expect(!files.hasMarker)
    }

    /// The originals are read and saved only on the way from nothing applied to applied: a re-apply never copies sTools'
    /// own pointer as the original.
    @Test func theOriginalsAreSavedOnlyWhileNothingIsApplied() {
        let directory = tempDirectory()
        let files = CursorFiles(supportDirectory: directory)
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        everywhere(controller)

        controller.setEnabled(true)
        #expect(Array(swapper.calls.prefix(3)) == CursorNames.arrow.map { FakeCursorSwapper.Call.read($0) }, "read before the apply")
        #expect(swapper.calls.dropFirst(3).first == .apply)
        controller.settings.size = 40
        controller.settings.fillHex = "#E4BC62"
        #expect(swapper.applyCount == 3)
        #expect(swapper.calls.filter { if case .read = $0 { true } else { false } }.count == 3)
        #expect(files.loadOriginals().map(\.size) == [CGSize(width: 28, height: 40), CGSize(width: 28, height: 40)])

        controller.setEnabled(false)
        #expect(swapper.restored.last?.allSatisfy { $0.size == CGSize(width: 28, height: 40) } == true)
        // Off and on again takes a fresh copy, of macOS's arrows again.
        controller.setEnabled(true)
        #expect(swapper.calls.filter { if case .read = $0 { true } else { false } }.count == 6)
        #expect(files.loadOriginals().map(\.size) == [CGSize(width: 28, height: 40), CGSize(width: 28, height: 40)])
        controller.setEnabled(false)
    }

    /// A marker left by a crash or a force quit: the arrow that was saved goes back as sTools starts, before anything else.
    @Test func aLeftoverMarkerRestoresFirstAtLaunch() throws {
        let directory = tempDirectory()
        let files = CursorFiles(supportDirectory: directory)
        try files.saveOriginals([RegisteredCursor.systemArrow(name: CursorNames.arrow[0])])
        try files.writeMarker()
        let swapper = FakeCursorSwapper()

        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        #expect(swapper.calls == [.restore])
        #expect(swapper.restored.first?.map(\.name) == [CursorNames.arrow[0]])
        #expect(!files.hasMarker)
        #expect(!controller.isApplied)
    }

    @Test func withoutAMarkerLaunchChangesNothing() throws {
        let directory = tempDirectory()
        try CursorFiles(supportDirectory: directory).saveOriginals([RegisteredCursor.systemArrow(name: CursorNames.arrow[0])])
        let swapper = FakeCursorSwapper()
        _ = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        #expect(swapper.calls.isEmpty)
    }

    /// Without a marker on disk the pointer can't be put back after a crash, so nothing is applied.
    @Test func whenTheMarkerCantBeWrittenNothingIsApplied() throws {
        let directory = tempDirectory()
        // A file where the Cursor folder goes.
        try Data().write(to: directory.appending(path: "Cursor"))
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        #expect(swapper.applyCount == 0)
        #expect(!controller.isApplied)
    }

    /// Quitting and Reset sTools restore through this, whatever the switch says.
    @Test func restoringPutsTheArrowBackOnce() {
        let directory = tempDirectory()
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        controller.restorePointer()
        #expect(swapper.restoreCount == 1)
        #expect(!controller.isApplied)
        #expect(!CursorFiles(supportDirectory: directory).hasMarker)
        controller.restorePointer()
        #expect(swapper.restoreCount == 1)
    }

    // MARK: Where, and Minecraft in front

    @Test func byDefaultItFollowsMinecraftInFront() async {
        let source = StaticMinecraftWindowSource(instances: [minecraft(frontmost: true)])
        let services = makeServices(directory: tempDirectory(), source: source)
        services.minecraft.start()
        defer { services.minecraft.stop() }
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: services, swapper: swapper)
        #expect(controller.settings.where == .whileMinecraftInFront)

        controller.setEnabled(true)
        #expect(swapper.applyCount == 1)

        source.instances = [minecraft(frontmost: false)]
        #expect(await waitUntil { swapper.restoreCount == 1 })
        #expect(!controller.isApplied)

        source.instances = [minecraft(frontmost: true)]
        #expect(await waitUntil { swapper.applyCount == 2 })
        #expect(controller.isApplied)

        source.instances = []
        #expect(await waitUntil { swapper.restoreCount == 2 })
        controller.setEnabled(false)
        #expect(swapper.restoreCount == 2, "nothing left to restore")
    }

    @Test func withoutMinecraftNothingIsApplied() {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        controller.setEnabled(true)
        #expect(swapper.applyCount == 0)
        #expect(controller.isEnabled)
    }

    /// Swaps happen only on a change: Minecraft's window moving while it stays in front swaps nothing.
    @Test func minecraftMovingInFrontSwapsNothing() async {
        let source = StaticMinecraftWindowSource(instances: [minecraft(frontmost: true)])
        let services = makeServices(directory: tempDirectory(), source: source)
        services.minecraft.start()
        defer { services.minecraft.stop() }
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: services, swapper: swapper)
        controller.setEnabled(true)
        let looks = controller.lookCount

        source.instances = [minecraft(frontmost: true, x: 40)]
        #expect(await waitUntil { controller.lookCount > looks })
        #expect(swapper.applyCount == 1)
        #expect(swapper.restoreCount == 0)
        controller.setEnabled(false)
    }

    @Test func everywhereIgnoresMinecraft() async {
        let source = StaticMinecraftWindowSource(instances: [minecraft(frontmost: false)])
        let services = makeServices(directory: tempDirectory(), source: source)
        services.minecraft.start()
        defer { services.minecraft.stop() }
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: services, swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        #expect(swapper.applyCount == 1)

        let looks = controller.lookCount
        source.instances = [minecraft(frontmost: true)]
        #expect(await waitUntil { controller.lookCount > looks })
        source.instances = []
        #expect(await waitUntil { controller.lookCount > looks + 1 })
        #expect(swapper.applyCount == 1)
        #expect(swapper.restoreCount == 0)
        controller.setEnabled(false)
    }

    @Test func changingWhereSwapsAtOnce() {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        controller.setEnabled(true)
        #expect(swapper.applyCount == 0)
        controller.settings.where = .everywhere
        #expect(swapper.applyCount == 1)
        controller.settings.where = .whileMinecraftInFront
        #expect(swapper.restoreCount == 1)
    }

    // MARK: Settings

    @Test func aSettingsChangeReappliesAtOnce() throws {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        controller.settings.size = 20
        #expect(swapper.applyCount == 2)
        #expect(swapper.applied.last?.size == CGSize(width: 26, height: 26))
        controller.settings.size = 20
        #expect(swapper.applyCount == 2, "the same value changes nothing")
        controller.settings.shape = .plus
        #expect(swapper.applyCount == 3)
        #expect(swapper.restoreCount == 0, "a change re-applies without restoring first")
        controller.setEnabled(false)
    }

    @Test func settingsAreSaved() async {
        let directory = tempDirectory()
        let services = makeServices(directory: directory)
        let controller = CustomCursorController(services: services, swapper: FakeCursorSwapper())
        controller.settings.size = 33
        await services.settings.flush()
        #expect(SettingsStore(directory: directory).load(CustomCursorSettings.self).size == 33)
    }

    @Test func resettingGoesBackToTheDefaults() {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        everywhere(controller)
        controller.settings.size = 50
        controller.resetToDefault()
        #expect(controller.settings == .defaultValue)
    }

    // MARK: Images

    @Test func choosingAnImageUsesItWithItsTopLeftClicking() throws {
        let directory = tempDirectory()
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        let picked = directory.appending(path: "picked.png")
        writePNG(width: 24, height: 30, to: picked)

        controller.importImage(from: picked)
        #expect(controller.settings.shape == .image)
        #expect(controller.settings.clickPoint == .topLeft)
        let name = try #require(controller.settings.imageName)
        #expect(name.hasPrefix("Images/"))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: name).path), "copied into Images, as the Crosshair's")
        #expect(controller.imageImportError == nil)
        #expect(swapper.applied.last?.size == CGSize(width: 24, height: 30))
        #expect(swapper.applied.last?.hotSpot == .zero)
        controller.setEnabled(false)
    }

    @Test func aSavedImageIsLoadedAtLaunch() throws {
        let directory = tempDirectory()
        let first = CustomCursorController(services: makeServices(directory: directory), swapper: FakeCursorSwapper())
        let picked = directory.appending(path: "picked.png")
        writePNG(width: 16, height: 16, to: picked)
        first.importImage(from: picked)
        let saved = first.settings

        let services = makeServices(directory: directory)
        services.settings.save(saved)
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: services, swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        #expect(swapper.applied.last?.size == CGSize(width: 16, height: 16))
        controller.setEnabled(false)
    }

    @Test func aFileThatIsntAnImageSaysWhyAndKeepsTheShape() {
        let directory = tempDirectory()
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: FakeCursorSwapper())
        let bogus = directory.appending(path: "notes.txt")
        try? "hello".write(to: bogus, atomically: true, encoding: .utf8)
        controller.importImage(from: bogus)
        #expect(controller.imageImportError != nil)
        #expect(controller.settings.shape == .dot)
    }

    /// The Image shape with no image shows macOS's own arrow: there's nothing to draw.
    @Test func theImageShapeWithoutAnImageRestores() {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        everywhere(controller)
        controller.setEnabled(true)
        controller.settings.shape = .image
        #expect(swapper.restoreCount == 1)
        #expect(!controller.isApplied)
        controller.settings.shape = .dot
        #expect(swapper.applyCount == 2)
        controller.setEnabled(false)
    }

    // MARK: Not supported

    @Test func withoutTheCallsItNeverSwitchesOn() throws {
        let directory = tempDirectory()
        try CursorFiles(supportDirectory: directory).writeMarker()
        let swapper = FakeCursorSwapper(isSupported: false)
        let controller = CustomCursorController(services: makeServices(directory: directory), swapper: swapper)
        everywhere(controller)
        #expect(!controller.isSupported)
        controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(swapper.calls.isEmpty)
    }

    // MARK: Diagnostics

    @Test func theDiagnosticsSayWhatsGoingOn() {
        let swapper = FakeCursorSwapper()
        let controller = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: swapper)
        #expect(controller.diagnosticsSummary == "Off, not applied, While Minecraft is in front, calls found")
        everywhere(controller)
        controller.setEnabled(true)
        #expect(controller.diagnosticsSummary == "On, applied now, Everywhere, calls found")
        controller.setEnabled(false)
        let unsupported = CustomCursorController(services: makeServices(directory: tempDirectory()), swapper: FakeCursorSwapper(isSupported: false))
        #expect(unsupported.diagnosticsSummary == "Off, not applied, While Minecraft is in front, calls missing")
    }
}
