import AppKit
import STDesign
import SwiftUI
import Testing
@testable import ScreenRecording
@testable import STPlatform

/// Where the Save/Delete question goes (spec 5.4.4). Pure math: nothing is shown.
@Suite("Recording question placement")
struct RecordingDecisionLayoutTests {
    private let size = CGSize(width: 440, height: 300)

    @Test func overSToolsWindowItIsCenteredOnIt() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let window = CGRect(x: 200, y: 100, width: 900, height: 700)
        #expect(RecordingDecisionLayout.frame(size: size, over: window, on: screen) == CGRect(x: 430, y: 300, width: 440, height: 300))
    }

    /// On Minecraft's display it sits just above the middle, so the crosshair at the center stays clear.
    @Test func onADisplayItSitsJustAboveTheMiddle() {
        let screen = CGRect(x: -9000, y: -9000, width: 1920, height: 1055)
        let frame = RecordingDecisionLayout.frame(size: size, over: nil, on: screen)
        #expect(frame.midX == screen.midX)
        #expect(frame.minY == (screen.midY + RecordingDecisionLayout.centerClearance).rounded())
        #expect(screen.contains(frame))
    }

    @Test func itAlwaysStaysOnTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1147, height: 720)
        let hanging = CGRect(x: 900, y: -200, width: 600, height: 400)
        let frame = RecordingDecisionLayout.frame(size: size, over: hanging, on: screen)
        #expect(screen.contains(frame))
        let short = CGRect(x: 0, y: 0, width: 800, height: 340)
        #expect(short.contains(RecordingDecisionLayout.frame(size: size, over: nil, on: short)))
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(RecordingDecisionLayout.frame(size: size, over: nil, on: tiny) == tiny)
    }
}

/// The question itself, laid out in a window that's never ordered in, so nothing reaches the screen.
@Suite("Recording question", .serialized) @MainActor
struct RecordingDecisionViewTests {
    private struct Fixture {
        let directory: URL
        let controller: ScreenRecordingController
        let finished: ScreenRecordingController.Finished

        @MainActor
        init() {
            directory = FileManager.default.temporaryDirectory.appending(path: "stools-question-\(UUID().uuidString)", directoryHint: .isDirectory)
            let services = ToolServices(
                settings: SettingsStore(directory: directory), displays: DisplayDirectory(screenProvider: { [] }),
                minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])),
                permissions: PermissionCenter(prober: AlwaysGranted()))
            controller = ScreenRecordingController(services: services, loadAvailable: { _ in AvailableSources() }, inProcessAudio: InProcessAudio())
            controller.options.folderPath = directory.appending(path: "Movies").path
            finished = ScreenRecordingController.Finished(
                files: [directory.appending(path: "2026-10-21 21.04.37.mov")], seconds: 754, droppedFrames: 0,
                explanation: nil, name: "2026-10-21 21.04.37")
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private struct AlwaysGranted: PermissionProbing {
        func status(for permission: Permission) -> PermissionStatus { .granted }
        func request(_ permission: Permission) async -> PermissionStatus { .granted }
    }

    @Test func itSaysWhereSaveAndEscPutTheRecording() {
        let fixture = Fixture()
        defer { fixture.remove() }
        var options = fixture.controller.options
        options.fileType = .mp4
        let finished = fixture.finished
        #expect(RecordingDecisionView.lengthLine(finished) == "00:12:34 long.")
        let folder = (options.folderPath as NSString).abbreviatingWithTildeInPath
        #expect(RecordingDecisionView.savedAsLine(name: "Seed 1", finished: finished, options: options)
                == "Saved as Seed 1.mp4 in \(folder).")
        #expect(RecordingDecisionView.savedAsLine(name: "  ", finished: finished, options: options)
                == "Without a name it\u{2019}s saved as 2026-10-21 21.04.37.mp4 in \(folder).")
        #expect(RecordingDecisionView.escapeLine(finished: finished, options: options)
                == "Esc saves it as 2026-10-21 21.04.37.mp4, so nothing is lost.")
        var split = finished
        split.files.append(fixture.directory.appending(path: "2026-10-21 21.04.37 part 2.mov"))
        #expect(RecordingDecisionView.lengthLine(split) == "00:12:34 long, in 2 files.")
    }

    /// A name that's already in the folder isn't the one Save or Esc will use, so the lines name the free one.
    @Test func itNamesTheFreeNameWhenTheTypedOrDateNameIsTaken() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        for name in ["Seed 1.mp4", "2026-10-21 21.04.37.mp4"] {
            try Data().write(to: fixture.directory.appending(path: name))
        }
        var options = fixture.controller.options
        options.fileType = .mp4
        let folder = (options.folderPath as NSString).abbreviatingWithTildeInPath
        #expect(RecordingDecisionView.savedAsLine(name: "Seed 1", finished: fixture.finished, options: options)
                == "Saved as Seed 1 2.mp4 in \(folder).")
        #expect(RecordingDecisionView.savedAsLine(name: "", finished: fixture.finished, options: options)
                == "Without a name it\u{2019}s saved as 2026-10-21 21.04.37 2.mp4 in \(folder).")
        #expect(RecordingDecisionView.escapeLine(finished: fixture.finished, options: options)
                == "Esc saves it as 2026-10-21 21.04.37 2.mp4, so nothing is lost.")
    }

    /// Dropped frames are counted in words that agree with the count, one frame included.
    @Test func droppedFramesReadInTheSingularForOne() {
        #expect(RecordingDecisionView.droppedLine(1).hasPrefix("1 frame was dropped. "))
        #expect(RecordingDecisionView.droppedLine(12).hasPrefix("12 frames were dropped. "))
        #expect(RecordBar.droppedText(1) == "1 frame dropped")
        #expect(RecordBar.droppedText(3) == "3 frames dropped")
    }

    /// The question lays out at its width, and its name field starts with the date and time.
    @Test func theNameFieldOffersTheDateAndTimeAndTakesTheKeyboard() throws {
        _ = STFont.register()
        let fixture = Fixture()
        defer { fixture.remove() }
        let theme = STTheme()
        let window = RecordingDecisionWindow()
        let draft = RecordingDecisionDraft(name: fixture.finished.name)
        window.contentView = NSHostingView(rootView: RecordingDecisionView(controller: fixture.controller, finished: fixture.finished, draft: draft)
            .environment(\.stTheme, theme)
            .stMotionRoot(theme))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        let size = try #require(window.contentView?.fittingSize)
        #expect(size.width == RecordingDecisionView.width)
        #expect(size.height > 150)

        // The field the panel gives the keyboard to once it's key (only on screen, so not here): the name, offered.
        let field = try #require(RecordingDecisionWindow.firstEditableField(in: window.contentView))
        #expect(field.stringValue == "2026-10-21 21.04.37")
        #expect(!window.isVisible)
    }

    /// The question, then its Delete confirmation, each draw (with a reason it stopped and dropped frames shown).
    @Test func theQuestionAndItsDeleteConfirmationRender() throws {
        _ = STFont.register()
        let fixture = Fixture()
        defer { fixture.remove() }
        var finished = fixture.finished
        finished.explanation = "The disk is almost full, so the recording was finished."
        finished.droppedFrames = 12
        let draft = RecordingDecisionDraft(name: finished.name)
        let question = Self.render(RecordingDecisionView(controller: fixture.controller, finished: finished, draft: draft))
        draft.confirmsDelete = true
        let confirmation = Self.render(RecordingDecisionView(controller: fixture.controller, finished: finished, draft: draft))
        #expect(Self.distinctColors(question) > 20)
        #expect(question.representation(using: .png, properties: [:]) != confirmation.representation(using: .png, properties: [:]))
    }

    private static func render(_ view: RecordingDecisionView) -> NSBitmapImageRep {
        let theme = STTheme()
        let host = NSHostingView(rootView: view.environment(\.stTheme, theme).stMotionRoot(theme))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255))
            }
        }
        return seen.count
    }

    /// Esc cancels the question from wherever the keyboard is.
    @Test func escInThePanelCancels() throws {
        let window = RecordingDecisionWindow()
        var cancels = 0
        window.onCancel = { cancels += 1 }
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
            keyCode: RecordingDecisionWindow.escapeKeyCode))
        window.sendEvent(escape)
        #expect(cancels == 1)
        window.cancelOperation(nil)
        #expect(cancels == 2)
        #expect(!window.isVisible)
    }

    /// It takes the keyboard without making sTools the active app, so Minecraft stays in front and macOS can't refuse
    /// it; it floats over full-screen apps and sTools' overlays on every Space, and stays up while sTools isn't in
    /// front, until it's answered.
    @Test func thePanelTakesTheKeyboardOverEverythingWithoutActivatingSTools() {
        let window = RecordingDecisionWindow()
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(!window.hidesOnDeactivate)
        #expect(window.level.rawValue > NSWindow.Level.screenSaver.rawValue)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    /// Presenting orders the panel in and gives it the keyboard by itself, whichever app is in front: nothing waits on
    /// sTools coming forward. Answering takes it away. On a window that never reaches the screen or the keyboard.
    @Test func presentingShowsTheQuestionByItselfAndAnsweringTakesItAway() throws {
        _ = STFont.register()
        let fixture = Fixture()
        defer { fixture.remove() }
        let window = InertDecisionWindow()
        let panel = RecordingDecisionPanel(theme: STTheme(), makeWindow: { window })
        panel.present(fixture.finished, for: fixture.controller)
        #expect(window.orderedInRegardless == 1)
        #expect(window.keyRequests == 1)
        let field = try #require(RecordingDecisionWindow.firstEditableField(in: window.contentView))
        #expect(field.stringValue == fixture.finished.name)

        // The key while it waits brings the same question back, as it was left.
        panel.present(fixture.finished, for: fixture.controller)
        #expect(window.orderedInRegardless == 2)
        #expect(window.keyRequests == 2)
        #expect(RecordingDecisionWindow.firstEditableField(in: window.contentView) === field)

        panel.dismiss()
        #expect(window.orderedOut == 1)
        #expect(window.contentView == nil)
    }
}

/// A question window that never reaches the screen or takes the keyboard: it counts what the panel asks of it.
private final class InertDecisionWindow: RecordingDecisionWindow {
    private(set) var orderedInRegardless = 0
    private(set) var keyRequests = 0
    private(set) var orderedOut = 0

    override func orderFrontRegardless() { orderedInRegardless += 1 }
    override func makeKey() { keyRequests += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderedInRegardless += 1
        keyRequests += 1
    }
    override func orderFront(_ sender: Any?) { orderedInRegardless += 1 }
    override func orderOut(_ sender: Any?) { orderedOut += 1 }
}
