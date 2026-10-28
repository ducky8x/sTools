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

    /// The question and the second panel Delete opens each draw (with a reason it stopped and dropped frames shown), and
    /// differ.
    @Test func theQuestionAndItsDeleteConfirmationRender() throws {
        _ = STFont.register()
        let fixture = Fixture()
        defer { fixture.remove() }
        var finished = fixture.finished
        finished.explanation = "The disk is almost full, so the recording was finished."
        finished.droppedFrames = 12
        let draft = RecordingDecisionDraft(name: finished.name)
        let question = Self.render(RecordingDecisionView(controller: fixture.controller, finished: finished, draft: draft))
        let confirmation = Self.render(RecordingDeleteConfirmationView(controller: fixture.controller, draft: draft))
        #expect(Self.distinctColors(question) > 20)
        #expect(Self.distinctColors(confirmation) > 10)
        #expect(question.representation(using: .png, properties: [:]) != confirmation.representation(using: .png, properties: [:]))
    }

    static func render(_ view: some View) -> NSBitmapImageRep {
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

    static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
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

/// What Delete… leads to (spec 5.4.4): a second panel, in the question's style and place, that asks once more and
/// answers Yes or No. No is the default and the cancel, so neither Return nor Esc deletes by accident.
@Suite("Recording delete confirmation", .serialized) @MainActor
struct RecordingDeleteConfirmationTests {
    private struct Fixture {
        let directory: URL
        let controller: ScreenRecordingController
        let finished: ScreenRecordingController.Finished

        @MainActor
        init() {
            directory = FileManager.default.temporaryDirectory.appending(path: "stools-delete-question-\(UUID().uuidString)", directoryHint: .isDirectory)
            let services = ToolServices(
                settings: SettingsStore(directory: directory), displays: DisplayDirectory(screenProvider: { [] }),
                minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])),
                permissions: PermissionCenter(prober: AlwaysGranted()))
            controller = ScreenRecordingController(services: services, loadAvailable: { _ in AvailableSources() }, inProcessAudio: InProcessAudio())
            controller.options.folderPath = directory.appending(path: "Movies").path
            finished = ScreenRecordingController.Finished(
                files: [directory.appending(path: "2026-10-27 09.00.00.mov")], seconds: 61, droppedFrames: 0,
                explanation: nil, name: "2026-10-27 09.00.00")
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private struct AlwaysGranted: PermissionProbing {
        func status(for permission: Permission) -> PermissionStatus { .granted }
        func request(_ permission: Permission) async -> PermissionStatus { .granted }
    }

    private func keyDown(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// The words are ducky's, exactly (2026-10-27). VoiceOver and Voice Control read a button's visible title first, so
    /// the spoken labels start with it and then say what the button does. (SwiftUI builds its accessibility tree only
    /// for a running assistive client, so there is no tree to walk here; the labels are the views' own constants.)
    @Test func theSecondPanelAsksExactlyWhatDuckyWrote() {
        #expect(RecordingDeleteConfirmationView.prompt
            == "Do you really want to delete this recording? It will be gone forever (a long time!)")
        #expect(RecordingDeleteConfirmationView.yesTitle == "Yes")
        #expect(RecordingDeleteConfirmationView.noTitle == "No")
        #expect(RecordingDeleteConfirmationView.yesSpokenLabel.hasPrefix("Yes"))
        #expect(RecordingDeleteConfirmationView.noSpokenLabel.hasPrefix("No"))
        #expect(RecordingDeleteConfirmationView.yesSpokenLabel != RecordingDeleteConfirmationView.noSpokenLabel)
    }

    /// The second panel is as wide as the first, so it reads as the same panel with another question.
    @Test func theSecondPanelHasTheQuestionsWidth() throws {
        _ = STFont.register()
        let fixture = Fixture()
        defer { fixture.remove() }
        let draft = RecordingDecisionDraft(name: fixture.finished.name)
        let theme = STTheme()
        let host = NSHostingView(rootView: RecordingDeleteConfirmationView(controller: fixture.controller, draft: draft)
            .environment(\.stTheme, theme).stMotionRoot(theme))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == RecordingDecisionView.width)
        #expect(host.fittingSize.height > 80)
        #expect(host.fittingSize.height < RecordingDecisionView.width)
    }

    private func presented(_ fixture: Fixture, theme: STTheme = STTheme()) -> (RecordingDecisionPanel, InertDecisionWindow) {
        _ = STFont.register()
        let window = InertDecisionWindow()
        let panel = RecordingDecisionPanel(theme: theme, makeWindow: { window })
        panel.present(fixture.finished, for: fixture.controller)
        return (panel, window)
    }

    /// Delete… swaps the question for the second panel in the same window: same place (centered where the first was),
    /// its own height, and the window stays the non-activating panel it was. Nothing is ordered in or out again.
    @Test func deleteOpensTheSecondPanelInTheSamePlace() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let (panel, window) = presented(fixture)
        let draft = try #require(panel.currentDraft)
        let question = try #require(window.contentView)
        let before = window.frame
        draft.askToDelete()
        let confirmation = try #require(window.contentView)
        #expect(confirmation !== question)
        #expect(draft.confirmsDelete)
        #expect(window.frame.size.width == RecordingDecisionView.width)
        #expect(window.frame.size.height == confirmation.fittingSize.height.rounded(.up))
        #expect(abs(window.frame.midX - before.midX) <= 1)
        #expect(abs(window.frame.midY - before.midY) <= 1)
        #expect(window.orderedInRegardless == 1)
        #expect(window.orderedOut == 0)
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(window.level.rawValue > NSWindow.Level.screenSaver.rawValue)
        #expect(window.accessibilityLabel() != nil)
        panel.dismiss()
    }

    /// No goes back to the question as it was: the same view with the same name field, the typed name still in it.
    @Test func noGoesBackToTheQuestionWithItsStateIntact() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let (panel, window) = presented(fixture)
        let draft = try #require(panel.currentDraft)
        let question = try #require(window.contentView)
        let field = try #require(RecordingDecisionWindow.firstEditableField(in: question))
        draft.name = "Seed 7 the good one"
        question.layoutSubtreeIfNeeded()
        let before = window.frame
        draft.askToDelete()
        draft.keep()
        #expect(window.contentView === question)
        #expect(RecordingDecisionWindow.firstEditableField(in: window.contentView) === field)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(draft.name == "Seed 7 the good one")
        #expect(field.stringValue == "Seed 7 the good one")
        #expect(!draft.confirmsDelete)
        #expect(window.frame == before, "the question comes back where it was")
        #expect(window.orderedInRegardless == 1)
        panel.dismiss()
    }

    /// Esc is No in the second panel: it steps back to the question and deletes nothing (and doesn't save); in the
    /// question it still cancels the question, saving under the date and time.
    @Test func escInTheSecondPanelIsNo() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let (panel, window) = presented(fixture)
        let draft = try #require(panel.currentDraft)
        let question = try #require(window.contentView)
        draft.askToDelete()
        window.sendEvent(try keyDown("\u{1B}", keyCode: RecordingDecisionWindow.escapeKeyCode, in: window))
        #expect(!draft.confirmsDelete)
        #expect(window.contentView === question)
        panel.dismiss()
    }

    /// Return is No in the second panel too: the default button is the safe one.
    @Test func returnInTheSecondPanelIsNo() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let (panel, window) = presented(fixture)
        let draft = try #require(panel.currentDraft)
        draft.askToDelete()
        window.contentView?.layoutSubtreeIfNeeded()
        window.sendEvent(try keyDown("\r", keyCode: 36, in: window))
        #expect(!draft.confirmsDelete, "Return pressed No")
        panel.dismiss()
    }

    /// Return belongs to the name field on the question (it saves) and to No on the second panel; it never reaches Yes.
    @Test func returnIsNoOnlyOnTheSecondPanel() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let (panel, window) = presented(fixture)
        let draft = try #require(panel.currentDraft)
        #expect(window.onDefaultAction == nil)
        draft.askToDelete()
        #expect(window.onDefaultAction != nil)
        draft.keep()
        #expect(window.onDefaultAction == nil)
        draft.askToDelete()
        panel.dismiss()
        #expect(window.onDefaultAction == nil)
    }

    /// The key (or the page's Save or Delete…) while the second panel waits brings that panel forward, as it was left.
    @Test func presentingAgainKeepsTheSecondPanelUp() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let (panel, window) = presented(fixture)
        let draft = try #require(panel.currentDraft)
        draft.askToDelete()
        let confirmation = try #require(window.contentView)
        panel.present(fixture.finished, for: fixture.controller)
        #expect(window.contentView === confirmation)
        #expect(draft.confirmsDelete)
        #expect(window.orderedInRegardless == 2)
        panel.dismiss()
    }

    /// Answering takes the panel away whichever step it was on; the next question starts on the question.
    @Test func dismissingFromTheSecondPanelLeavesNothingBehind() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let (panel, window) = presented(fixture)
        let draft = try #require(panel.currentDraft)
        draft.askToDelete()
        panel.dismiss()
        #expect(window.orderedOut == 1)
        #expect(window.contentView == nil)
        #expect(panel.currentDraft == nil)
        panel.present(fixture.finished, for: fixture.controller)
        let next = try #require(panel.currentDraft)
        #expect(!next.confirmsDelete)
        #expect(RecordingDecisionWindow.firstEditableField(in: window.contentView) != nil)
        panel.dismiss()
    }

    /// Reduce animations: the panel shows and goes without AppKit's pop, and swapping to the second panel moves
    /// nothing (it is instant either way).
    @Test func reduceAnimationsTurnsThePanelsMotionOff() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let reduced = STTheme(motionMode: .reduced)
        let (panel, window) = presented(fixture, theme: reduced)
        #expect(window.animationBehavior == .none)
        let draft = try #require(panel.currentDraft)
        draft.askToDelete()
        #expect(window.animationBehavior == .none)
        panel.dismiss()

        let full = STTheme()
        let (otherPanel, otherWindow) = presented(Fixture(), theme: full)
        #expect(otherWindow.animationBehavior == .alertPanel)
        otherPanel.dismiss()
    }
}

/// A question window that never reaches the screen or takes the keyboard: it counts what the panel asks of it.
final class InertDecisionWindow: RecordingDecisionWindow {
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
