import AppKit
import Foundation
import os
import STDesign
@testable import ScreenRecording
@testable import STPlatform
import Testing
@testable import sTools

/// No capture at all: a recording is a blank canvas, written to the harness's folder. A microphone in the layout gets a
/// stand-in that only takes `startTakes` to start, as a real source's start can. Nothing asks for a permission.
@MainActor
private final class NoCapture: CaptureFactory {
    let startTakes: Duration?
    init(startTakes: Duration?) { self.startTakes = startTakes }
    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func audio(for source: AudioSource) -> (any AudioCapture)? { startTakes.map(SlowMicrophone.init) }
    func minecraftAudio(processID: Int32) -> (any AudioCapture)? { nil }
}

/// A microphone that takes a while to start and then hears nothing.
private final class SlowMicrophone: AudioCapture, @unchecked Sendable {
    let startTakes: Duration
    init(startTakes: Duration) { self.startTakes = startTakes }
    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws { try? await Task.sleep(for: startTakes) }
    func stop() async {}
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

/// The recording's frame clock, fired by the test: no frame is written until it fires.
private final class HandTickDriver: TickDriver, @unchecked Sendable {
    private let handler = HandlerSlot<Void>()
    func start(interval: Double, handler: @escaping @Sendable () -> Void) { self.handler.set { handler() } }
    func stop() { handler.clear() }
    var isRunning: Bool { handler.isSet }
    func fire() { handler(()) }
}

private let startingLine = "Starting the recording\u{2026}"
private let stoppedLine = "Recording stopped \u{00B7} Screen Recording off"
private let canceledLine = "Recording canceled \u{00B7} Screen Recording off"

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
    /// Arming and starting a recording takes seconds while the whole suite runs at once. At the start of a run on a
    /// busy Mac the page-render tests hold the main actor for tens of seconds, and the recording's phase changes on it.
    static let patience: Duration = .seconds(60)

    /// `hotkeys` is the `hotkeys.json` the launch finds: an existing, empty list by default; nil for a new install,
    /// which starts with ⌘1–⌘5. `sourcesTake`: how long the sources take to come up when the tool switches on, as the
    /// captures starting can on real hardware (a microphone that takes that long is added). `screenRecording`: Screen &
    /// System Audio Recording, granted by default (Accessibility always is).
    init(hotkeys: HotkeySettings? = HotkeySettings(), sourcesTake: Duration? = nil,
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
            services: services, makeFactory: { _ in NoCapture(startTakes: sourcesTake) },
            loadAvailable: { _ in AvailableSources() },
            inProcessAudio: InProcessAudio(), decisionPresenter: question)
        if sourcesTake != nil {
            recording.updateLayout { $0.add(AudioSource(kind: .microphone(uniqueID: "slow"), name: "Microphone")) }
        }
        recording.options.folderPath = directory.appending(path: "Movies", directoryHint: .isDirectory).path
        recording.options.canvas = .custom(PixelSize(width: 320, height: 180))
        recording.options.frameRate = .fps30
        recording.options.fileType = .mov
        // A start gives up when its first frame isn't in the file in five seconds, which a busy Mac can outlast. The
        // line over the game then says the encoder didn't respond, and the phase never reaches `.recording`.
        recording.firstFrameTimeout = .seconds(120)
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
    /// The page's Hotkey row says what the one key does: start, stop and the question, and that the stop switches the
    /// tool off. With Ask Save or Delete on stop off, the stop saves under the date and time instead.
    @Test func theHotkeyRowSaysWhatTheOneKeyDoes() throws {
        let harness = RecordingHarness()
        let row = try #require(ToolHotkeyRow(model: harness.model, tool: .screenRecording))
        #expect(row.purposeLine == "Starts a recording; press again to stop, name it and Save or Delete. "
            + "Stopping switches Screen Recording off.")
        harness.recording.options.askSaveDelete = false
        #expect(row.purposeLine == "Starts a recording; press again to stop and save it under its date and time. "
            + "Stopping switches Screen Recording off.")
    }

    /// Off, the press switches the tool on and its sources start: the line says the recording is starting, without the
    /// seal, and "Recording started" follows with the seal once the recording writes.
    @Test func offTheKeySwitchesTheToolOnAndRecordsAtOnce() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(!harness.model.isOn(.screenRecording))
        harness.press(id)
        #expect(harness.hud.lines == [startingLine])
        #expect(harness.hud.presented.map(\.sealed) == [false])
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        #expect(harness.model.isOn(.screenRecording))
        #expect(harness.model.status(of: .screenRecording) == .on)
        #expect(harness.hud.lines == [startingLine, "Recording started"])
        #expect(harness.hud.presented.map(\.sealed) == [false, true])
        await harness.recording.stopRecording(explanation: nil)
        harness.recording.delete()
    }

    /// "Recording started" (its line, the stamp and VoiceOver's announcement, all the confirmation's) shows when the
    /// writer puts the first frame in the file, not at the press. Here the recording's clock is fired by hand.
    @Test func recordingStartedShowsOnceTheFirstFrameIsInTheFile() async throws {
        let harness = RecordingHarness()
        let driver = HandTickDriver()
        harness.recording.makeTickDriver = { driver }
        let id = harness.addKey()
        harness.press(id)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { driver.isRunning })
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.hud.lines == [startingLine])
        #expect(harness.recording.phase == .starting)
        driver.fire()
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.hud.lines.count == 2 })
        #expect(harness.hud.lines == [startingLine, "Recording started"])
        #expect(harness.recording.phase == .recording)
        await harness.recording.stopRecording(explanation: nil)
        harness.recording.delete()
    }

    /// A start that fails after the press says why over the game, without the seal, and the tool goes off.
    @Test func aStartThatFailsSaysWhyOverTheGame() async throws {
        let harness = RecordingHarness()
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        let blocker = harness.directory.appending(path: "not a folder")
        try Data().write(to: blocker)
        harness.recording.options.folderPath = blocker.appending(path: "Movies").path
        let id = harness.addKey()
        harness.press(id)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.hud.lines.count == 2 })
        #expect(harness.hud.lines == [startingLine, "Recording couldn\u{2019}t start: the recordings folder can\u{2019}t be written to \u{00B7} Screen Recording off"])
        #expect(harness.hud.presented.map(\.sealed) == [false, false])
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.recording.phase == .idle)
        #expect(harness.question.presented == 0)
    }

    /// Switched on by hand, the sources already run, so the press shows nothing of its own: "Recording started" comes
    /// a moment later, as the recording writes.
    @Test func anArmedToolsKeyConfirmsOnlyOnceWritingBegins() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        harness.model.setTool(.screenRecording, on: true)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.sourcesAreReady })
        harness.press(id)
        #expect(harness.hud.lines.isEmpty)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        #expect(harness.hud.lines == ["Recording started"])
        #expect(harness.hud.presented.map(\.sealed) == [true])
        await harness.recording.stopRecording(explanation: nil)
        harness.recording.delete()
    }

    /// Off, the first press starts the sources, which take a moment. A second press then cancels the start, as one
    /// during a countdown does: nothing is written or asked, the tool is off and the line says so. (It used to start
    /// a second recording, one of which kept writing unseen.)
    @Test func aSecondPressWhileItStartsCancelsIt() async throws {
        let harness = RecordingHarness(sourcesTake: .milliseconds(300))
        let id = harness.addKey()
        harness.press(id)
        #expect(harness.recording.phase == .starting)
        #expect(harness.model.isOn(.screenRecording))
        try await Task.sleep(for: .milliseconds(50))
        harness.press(id)
        #expect(harness.recording.phase == .idle)
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.hud.lines == [startingLine, canceledLine])
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
        #expect(harness.hud.lines.suffix(3) == [startingLine, "Recording started", stoppedLine])
        harness.recording.delete()
    }

    /// A new install's key set gives Screen Recording ⌘4 with its one action, so once hotkeys are on, ⌘4 records,
    /// stops and asks like the key its page sets; answering turns the tool off.
    @Test func aNewInstallsCommandFourRecordsWithTheOneAction() async throws {
        let harness = RecordingHarness(hotkeys: nil)
        let own = try #require(ToolHotkey.own(for: .startStopRecording, in: harness.model.hotkeys.bindings))
        #expect(own.combo.displayString == "⌘4")
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
        #expect(harness.hud.lines == [startingLine, "Recording started", stoppedLine])
        // Already off: the stop switched the tool off before the question came up.
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.model.status(of: .screenRecording) == .off)
        // The key while it waits brings the question back, says why without the seal, and starts nothing.
        harness.press(id)
        #expect(harness.question.presented == 2)
        #expect(harness.recording.phase == .deciding)
        #expect(harness.hud.presented.last?.line == "Save or Delete the last recording first")
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

    /// Settings ▸ Reset All Tools resets Screen Recording's settings but keeps its sources and layout, as its
    /// confirmation says (`AppModel.resetAllToolsMessage`).
    @Test func resetAllToolsKeepsTheSourcesAndLayout() {
        let harness = RecordingHarness()
        harness.recording.updateLayout { $0.add(AudioSource(kind: .microphone(uniqueID: "kept"), name: "Microphone")) }
        let layoutBefore = harness.recording.layout

        harness.model.resetAllToolsToDefault()

        #expect(harness.recording.options == RecordingOptions.defaultValue)
        #expect(harness.recording.layout == layoutBefore)
        #expect(harness.recording.layout.audioSources.contains { $0.name == "Microphone" })
    }
}

/// Screen Recording's own switch (the tool page's, the sidebar's, the Prologue trial's) does what its key does with the
/// tool off: it switches the tool on and starts a recording (spec 5.4.4). Switching on any other way (restoring the
/// tools that were on at quit, the Prologue's test, a start the controller asks for) never records by itself.
@MainActor
@Suite("AppModel Screen Recording switch", .serialized)
struct AppModelRecordingSwitchTests {
    /// Off, flipping the switch on switches the tool on and records, line for line as the key does: "Starting the
    /// recording…" without the seal, then "Recording started" with it once the first frame is in the file.
    @Test func switchingOnStartsARecordingAsTheKeyDoes() async throws {
        let harness = RecordingHarness()
        let binding = harness.model.switchBinding(.screenRecording)
        #expect(!binding.wrappedValue)
        binding.wrappedValue = true
        // At the flip, not a turn later: the switch stays on and a start is under way.
        #expect(harness.model.isOn(.screenRecording))
        #expect(harness.recording.phase == .starting)
        #expect(harness.hud.lines == [startingLine])
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        #expect(harness.hud.lines == [startingLine, "Recording started"])
        #expect(harness.hud.presented.map(\.sealed) == [false, true])
        #expect(harness.model.status(of: .screenRecording) == .on)
        await harness.recording.stopRecording(explanation: nil)
        harness.recording.delete()
    }

    /// The switch on the way back: turning it off while it records stops, asks Save or Delete and leaves the tool off.
    @Test func switchingOffStillStopsAndAsks() async throws {
        let harness = RecordingHarness()
        let binding = harness.model.switchBinding(.screenRecording)
        binding.wrappedValue = true
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        try await Task.sleep(for: .milliseconds(300))
        binding.wrappedValue = false
        #expect(!harness.model.isOn(.screenRecording))
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .deciding })
        #expect(harness.question.presented == 1)
        harness.recording.delete()
        #expect(!harness.model.isOn(.screenRecording))
    }

    /// With the question off, the stop saves under the date and time, as it does for the key.
    @Test func switchingOffWithTheQuestionOffSavesAtOnce() async throws {
        let harness = RecordingHarness()
        harness.recording.options.askSaveDelete = false
        let binding = harness.model.switchBinding(.screenRecording)
        binding.wrappedValue = true
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        try await Task.sleep(for: .milliseconds(300))
        binding.wrappedValue = false
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.savedFileNames().count == 1 })
        #expect(harness.question.presented == 0)
        #expect(!harness.model.isOn(.screenRecording))
    }

    /// The key and the switch are one thing: after one, the other undoes it.
    @Test func theKeyStopsWhatTheSwitchStarted() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        harness.model.switchBinding(.screenRecording).wrappedValue = true
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .recording })
        try await Task.sleep(for: .milliseconds(300))
        harness.press(id)
        #expect(!harness.model.isOn(.screenRecording))
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.phase == .deciding })
        harness.recording.delete()
    }

    /// Without Screen & System Audio Recording the switch, like the key, starts nothing: the tool stays off, nothing
    /// asks macOS for the permission, and the line says what's missing, without the seal.
    @Test func withoutScreenRecordingPermissionTheSwitchStartsNothing() async throws {
        let harness = RecordingHarness(screenRecording: .denied)
        harness.model.switchBinding(.screenRecording).wrappedValue = true
        #expect(!harness.model.isOn(.screenRecording))
        #expect(harness.recording.phase == .idle)
        #expect(harness.hud.lines == ["Screen Recording needs Screen & System Audio Recording"])
        #expect(harness.hud.presented.map(\.sealed) == [false])
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.savedFileNames().isEmpty)
        #expect(!harness.prober.requested.contains(.screenRecording))
    }

    /// Switching on while the file of the last recording is still being finished, or its question waits, only switches
    /// the tool on (spec 5.4.4: it stays on with the sources the switch started): nothing records, nothing is asked
    /// again, and the question still waits.
    @Test func switchingOnWhileTheQuestionWaitsOnlySwitchesOn() async throws {
        let harness = RecordingHarness()
        let id = harness.addKey()
        #expect(await harness.recordByKey(id))
        #expect(!harness.model.isOn(.screenRecording))
        let lines = harness.hud.lines
        harness.model.switchBinding(.screenRecording).wrappedValue = true
        #expect(harness.model.isOn(.screenRecording))
        #expect(harness.recording.phase == .deciding)
        #expect(harness.question.presented == 1)
        #expect(harness.hud.lines == lines)
        harness.recording.delete()
        #expect(harness.recording.phase == .idle)
        #expect(harness.model.isOn(.screenRecording))
        harness.model.setTool(.screenRecording, on: false)
    }

    /// The same flip on a tool that's already on does nothing: no second recording.
    @Test func switchingOnAnArmedToolWithTheValueAlreadyOnStartsNothingMore() async throws {
        let harness = RecordingHarness()
        harness.model.setTool(.screenRecording, on: true)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.sourcesAreReady })
        harness.model.switchBinding(.screenRecording).wrappedValue = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.recording.phase == .idle)
        #expect(harness.hud.lines.isEmpty)
        harness.model.setTool(.screenRecording, on: false)
    }

    /// Restoring the tools that were on at quit (Settings ▸ General ▸ Advanced) switches Screen Recording back on as
    /// before and never records: only a person's flip of the switch does.
    @Test func restoringTheToolAtLaunchDoesNotStartARecording() async throws {
        let harness = RecordingHarness()
        harness.model.general = GeneralSettings(restoreToolsAtQuit: true, toolsOnAtQuit: ["screenRecording"])
        harness.model.restoreToolsIfNeeded()
        #expect(harness.model.isOn(.screenRecording))
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.sourcesAreReady })
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.recording.phase == .idle)
        #expect(harness.savedFileNames().isEmpty)
        #expect(harness.hud.lines.isEmpty)
        #expect(harness.model.isOn(.screenRecording))
        harness.model.setTool(.screenRecording, on: false)
    }

    /// Nothing but the person's flip records: the app's own switching on (what the Prologue's test and the page's
    /// Record ask for) leaves the start to the caller.
    @Test func theAppsOwnSwitchingOnDoesNotRecord() async throws {
        let harness = RecordingHarness()
        harness.model.setTool(.screenRecording, on: true)
        #expect(await waitUntil(timeout: RecordingHarness.patience) { harness.recording.sourcesAreReady })
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.recording.phase == .idle)
        #expect(harness.model.isOn(.screenRecording))
        harness.model.setTool(.screenRecording, on: false)
    }

    /// Other tools' switches are unchanged.
    @Test func otherSwitchesStillOnlySwitch() {
        let harness = RecordingHarness()
        harness.model.switchBinding(.crosshair).wrappedValue = true
        #expect(harness.model.isOn(.crosshair))
        #expect(harness.recording.phase == .idle)
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
