import AppKit
import Foundation
import STDesign
@testable import ScreenRecording
@testable import STPlatform
import Testing
@testable import sTools

/// No capture at all: a recording is a blank canvas, written to the harness's folder. Nothing asks for a permission.
@MainActor
private final class NoCapture: CaptureFactory {
    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func audio(for source: AudioSource) -> (any AudioCapture)? { nil }
    func minecraftAudio(processID: Int32) -> (any AudioCapture)? { nil }
}

/// Records what the controller asked of the Save/Delete question instead of showing the panel.
@MainActor
private final class FakeQuestion: RecordingDecisionPresenting {
    private(set) var presented = 0
    private(set) var dismissed = 0

    func present(for controller: ScreenRecordingController) { presented += 1 }
    func dismiss() { dismissed += 1 }
}

private let f5 = HotkeyCombo(keyCode: 96, modifiers: [])

/// The app with a real Screen Recording controller on fakes: no capture, no window, no sound, and the recordings go
/// to a temporary folder.
@MainActor
private final class RecordingHarness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-recording-app-\(UUID().uuidString)", directoryHint: .isDirectory)
    let question = FakeQuestion()
    let registrar = FakeHotkeyRegistrar()
    let hud = FakeHotkeyHUD()
    let prober: FakeProber
    let recording: ScreenRecordingController
    let model: AppModel
    /// Arming and starting a recording can take seconds while the whole suite runs at once.
    static let patience: Duration = .seconds(20)

    /// `hotkeys` is the `hotkeys.json` the launch finds: an existing, empty list by default; nil for a new install,
    /// which starts with ⌘1–⌘5. `armingTakes`: how long the sources take to come up when the tool switches on, as
    /// ScreenCaptureKit's listing and the captures starting can on real hardware. `screenRecording`: Screen & System
    /// Audio Recording, granted by default (Accessibility always is).
    init(hotkeys: HotkeySettings? = HotkeySettings(), armingTakes: Duration? = nil,
         screenRecording: PermissionStatus = .granted) {
        let store = SettingsStore(directory: directory, debounce: .milliseconds(10))
        store.save(AppState(prologueCompleted: true))
        if let hotkeys { store.save(hotkeys) }
        prober = FakeProber(accessibility: .granted)
        prober.set(.screenRecording, screenRecording)
        let services = ToolServices(
            settings: store, displays: DisplayDirectory(screenProvider: { [harnessDisplay] }),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])),
            permissions: PermissionCenter(prober: prober, openURL: { _ in }))
        recording = ScreenRecordingController(
            services: services, makeFactory: { _ in NoCapture() },
            loadAvailable: { _ in
                if let armingTakes { try? await Task.sleep(for: armingTakes) }
                return AvailableSources()
            },
            inProcessAudio: InProcessAudio(), decisionPresenter: question)
        recording.options.folderPath = directory.appending(path: "Movies", directoryHint: .isDirectory).path
        recording.options.canvas = .custom(PixelSize(width: 320, height: 180))
        recording.options.frameRate = .fps30
        recording.options.fileType = .mov
        model = AppModel(services: services, theme: STTheme(), sound: .silent, controllers: [.screenRecording: recording],
                         hotkeyRegistrar: registrar, hotkeyHUD: hud, loginItem: FakeLoginItem())
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Screen Recording's own hotkey, on and registered, as its page's Hotkey row sets it.
    func addKey() -> UUID {
        ToolHotkey.set(f5, for: .startStopRecording, in: model.hotkeys)
        model.hotkeys.isEnabled = true
        return model.hotkeys.bindings[0].id
    }

    func press(_ id: UUID) { registrar.onPress?(id) }

    /// Off: the key switches Screen Recording on and records; a moment later the key stops it and the question comes up.
    func recordByKey(_ id: UUID) async -> Bool {
        press(id)
        guard await waitUntil(timeout: Self.patience, { self.recording.phase == .recording }) else { return false }
        try? await Task.sleep(for: .milliseconds(300))
        press(id)
        return await waitUntil(timeout: Self.patience) { self.recording.phase == .deciding }
    }

    func savedFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: recording.options.folderPath)) ?? []).sorted()
    }
}

/// ducky's one Screen Recording key (spec 5.4.4, 6.1): it turns recording on and off; off asks for the name and Save
/// or Delete; once that's answered, the tool is off, by the key or the page's Stop alike.
@MainActor
@Suite("AppModel Screen Recording key", .serialized)
struct AppModelRecordingTests {
    @Test func offTheKeySwitchesTheToolOnAndRecordsAtOnce() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(!harness.model.isOn(.screenRecording))
        harness.press(id)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        #expect(harness.model.isOn(.screenRecording))
        #expect(harness.model.status(of: .screenRecording) == .on)
        #expect(harness.hud.lines == ["Recording started"])
        await harness.recording.stopRecording(explanation: nil)
        harness.recording.delete()
    }

    /// Off, the first press starts the sources, which take a moment. A second press then cancels the start, as one
    /// during a countdown does: nothing is written or asked, the tool is off and the line says so. (It used to start
    /// a second recording, one of which kept writing unseen.)
    @Test func aSecondPressWhileItStartsCancelsIt() async throws {
        let harness = RecordingHarness(armingTakes: .milliseconds(300))
        let id = harness.addKey()
        harness.press(id)
        #expect(harness.recording.phase == .starting)
        #expect(harness.model.isOn(.screenRecording))
        try await Task.sleep(for: .milliseconds(50))
        harness.press(id)
        #expect(harness.recording.phase == .idle)
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.hud.lines == ["Recording started", "Recording canceled"])
        // Long after the sources would have come up, still nothing.
        try await Task.sleep(for: .milliseconds(700))
        #expect(harness.recording.phase == .idle)
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.savedFileNames().isEmpty)
        #expect(harness.question.presented == 0)
        // The next press records as usual.
        #expect(await harness.recordByKey(id))
        #expect(harness.savedFileNames().count == 1)
        harness.recording.delete()
        #expect(!harness.model.isOn(.screenRecording))
    }

    /// Without Screen & System Audio Recording the key starts nothing: no recording (it would be a blank canvas), the
    /// tool stays off, nothing asks macOS for the permission over the game, and the line says what's missing, without
    /// the seal. The page's Allow… is where it's given.
    @Test func withoutScreenRecordingPermissionTheKeyStartsNothing() async throws {
        let harness = RecordingHarness(screenRecording: .denied)
        let id = harness.addKey()
        harness.press(id)
        #expect(harness.recording.phase == .idle)
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.hud.lines == ["Screen Recording needs Screen & System Audio Recording"])
        #expect(harness.hud.presented.map(\.sealed) == [false])
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.recording.phase == .idle)
        #expect(harness.savedFileNames().isEmpty)
        #expect(harness.question.presented == 0)
        #expect(!harness.prober.requested.contains(.screenRecording))
        // Once it's allowed, the next press records.
        harness.prober.set(.screenRecording, .granted)
        #expect(await harness.recordByKey(id))
        #expect(harness.hud.lines.suffix(2) == ["Recording started", "Recording stopped"])
        harness.recording.delete()
    }

    /// A new install's key set gives Screen Recording ⌘5 with its one action, so once hotkeys are on, ⌘5 records,
    /// stops and asks like the key its page sets; answering turns the tool off.
    @Test func aNewInstallsCommandFiveRecordsWithTheOneAction() async throws {
        let harness = RecordingHarness(hotkeys: nil)
        let own = try #require(ToolHotkey.own(for: .startStopRecording, in: harness.model.hotkeys.bindings))
        #expect(own.combo.displayString == "⌘5")
        harness.model.hotkeys.isEnabled = true
        #expect(harness.model.hotkeys.status(of: own.id) == .registered)
        #expect(await harness.recordByKey(own.id))
        #expect(harness.question.presented == 1)
        harness.recording.delete()
        #expect(!harness.model.isOn(.screenRecording))
    }

    @Test func whileRecordingTheKeyStopsAndAsks() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(await harness.recordByKey(id))
        #expect(harness.question.presented == 1)
        #expect(harness.hud.lines == ["Recording started", "Recording stopped"])
        // Already off: the stop switched the tool off before the question came up.
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.model.status(of: .screenRecording) == .off)
        // The key while it waits brings the question back, says why without the seal, and starts nothing.
        harness.press(id)
        #expect(harness.question.presented == 2)
        #expect(harness.recording.phase == .deciding)
        #expect(harness.hud.presented.last?.line == "Save or delete the last recording first")
        #expect(harness.hud.presented.last?.sealed == false)
        #expect(!harness.model.isOn(.screenRecording))
        harness.recording.delete()
        #expect(!harness.model.isOn(.screenRecording))
    }

    /// The press that stops a recording turns the sidebar's switch off right then, not once the question is answered.
    @Test func theSwitchGoesOffWithTheStopPress() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        harness.press(id)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.model.isOn(.screenRecording))
        harness.press(id)
        #expect(!harness.model.isOn(.screenRecording))
        #expect(!harness.recording.isEnabled)
        #expect(harness.question.presented == 0)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .deciding })
        #expect(harness.question.presented == 1)
        harness.recording.delete()
    }

    /// Quitting sTools while the question waits saves the recording under its date-and-time name.
    @Test func quittingWhileTheQuestionWaitsSavesIt() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(await harness.recordByKey(id))
        let name = try #require(harness.recording.finished?.name)
        await harness.model.shutDown()
        #expect(harness.savedFileNames() == ["\(name).mov"])
        #expect(harness.question.dismissed == 1)
        #expect(harness.recording.phase == .idle)
    }

    @Test func savingKeepsTheFileAndTurnsTheToolOff() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(await harness.recordByKey(id))
        await harness.recording.save(name: "Seed 1")
        #expect(harness.savedFileNames() == ["Seed 1.mov"])
        #expect(harness.question.dismissed == 1)
        #expect(!harness.model.isOn(.screenRecording))
        #expect(!harness.recording.isEnabled)
        #expect(harness.model.status(of: .screenRecording) == .off)
    }

    @Test func deletingRemovesTheFileAndTurnsTheToolOff() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(await harness.recordByKey(id))
        let file = try #require(harness.recording.finished?.files.first)
        harness.recording.delete()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(harness.savedFileNames().isEmpty)
        #expect(!harness.model.isOn(.screenRecording))
    }

    /// Canceling the naming saves it under the offered date-and-time name, so nothing is lost; the tool goes off.
    @Test func cancelingSavesUnderTheOfferedName() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(await harness.recordByKey(id))
        let name = try #require(harness.recording.finished?.name)
        await harness.recording.cancelDecision()
        #expect(harness.savedFileNames() == ["\(name).mov"])
        #expect(!harness.model.isOn(.screenRecording))
    }

    /// The page's Stop asks the same question, and the tool goes off after it too, even when it was switched on by hand.
    @Test func thePagesStopTurnsTheToolOffToo() async throws {
        let harness = RecordingHarness()
        harness.model.setTool(.screenRecording, on: true)
        await harness.recording.startRecording()
        #expect(harness.recording.phase == .recording)
        try await Task.sleep(for: .milliseconds(300))
        await harness.recording.stopRecording(explanation: nil)
        #expect(harness.recording.phase == .deciding)
        #expect(harness.question.presented == 1)
        await harness.recording.save(name: nil)
        #expect(harness.savedFileNames().count == 1)
        #expect(!harness.model.isOn(.screenRecording))
    }

    /// Closing the window mid-recording and choosing Stop and Save saves under the date and time, without the question.
    @Test func stopAndSaveFromTheWindowAsksNothing() async throws {
        let harness = RecordingHarness()
        harness.model.setTool(.screenRecording, on: true)
        await harness.recording.startRecording()
        try await Task.sleep(for: .milliseconds(300))
        await harness.recording.stopRecording(explanation: nil, savesWithoutAsking: true)
        #expect(harness.question.presented == 0)
        #expect(harness.savedFileNames().count == 1)
        #expect(!harness.model.isOn(.screenRecording))
    }
}

/// The recording question takes the keyboard over Minecraft without making sTools the active app (spec 5.4.4), yet
/// typing a name in it still sets aside the hotkeys on typed keys, as typing in sTools' window does (spec 6.1).
@MainActor
@Suite("Typing in the recording question")
struct RecordingQuestionTypingTests {
    @Test func typingInAPanelThatHasTheKeyboardWithSToolsInTheBackgroundCounts() {
        let editable = NSTextView()
        let readOnly = NSTextView()
        readOnly.isEditable = false
        #expect(HotkeyKeyWatcher.isTyping(appIsActive: false, firstResponder: editable, keyWindowIsNonactivatingPanel: true))
        #expect(!HotkeyKeyWatcher.isTyping(appIsActive: false, firstResponder: editable, keyWindowIsNonactivatingPanel: false))
        #expect(!HotkeyKeyWatcher.isTyping(appIsActive: false, firstResponder: readOnly, keyWindowIsNonactivatingPanel: true))
        #expect(!HotkeyKeyWatcher.isTyping(appIsActive: false, firstResponder: nil, keyWindowIsNonactivatingPanel: true))
    }

    /// Only a panel that takes the keyboard without activating sTools counts while sTools is in the background.
    @Test func theQuestionsKindOfPanelIsTheOneThatCounts() {
        let question = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        #expect(HotkeyKeyWatcher.takesKeysWithoutActivating(question))
        #expect(!HotkeyKeyWatcher.takesKeysWithoutActivating(window))
        #expect(!HotkeyKeyWatcher.takesKeysWithoutActivating(nil))
        #expect(!question.isVisible && !window.isVisible)
    }
}
