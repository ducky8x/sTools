import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import ScreenRecording
@testable import STPlatform

@MainActor
private final class FakeFactory: CaptureFactory {
    var bases: [UInt32: FakeVideoCapture] = [:]
    var videos: [UUID: FakeVideoCapture] = [:]
    var audios: [UUID: FakeAudioCapture] = [:]
    var minecraftAudio: FakeAudioCapture?
    /// Every capture made, in the order the factory made them.
    private(set) var videoCaptures: [FakeVideoCapture] = []
    private(set) var audioCaptures: [FakeAudioCapture] = []
    /// How many times Minecraft's capture was made: once per arming.
    private(set) var baseCount = 0
    /// The window IDs the window sources were captured by, in order.
    private(set) var capturedWindowIDs: [UInt32] = []
    /// The order the captures stopped in, "video" or "audio" each.
    let stops = StopLog()
    /// How long Minecraft's capture takes to start, as ScreenCaptureKit's can on real hardware.
    var baseStartTakes: Duration?
    /// Whether Minecraft's capture sends a first frame as it starts, as ScreenCaptureKit's does.
    var baseSendsFirstFrame = true

    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? {
        let first = baseSendsFirstFrame
            ? VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: 0, size: PixelSize(width: 320, height: 180)), hostTime: HostMediaClock().now())
            : nil
        let capture = FakeVideoCapture(name: "video", stops: stops, startTakes: baseStartTakes, firstFrame: first)
        bases[minecraftWindowID] = capture
        baseCount += 1
        videoCaptures.append(capture)
        return capture
    }

    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)? {
        if case .window(let reference) = source.kind { capturedWindowIDs.append(reference.windowID) }
        let capture = FakeVideoCapture(name: "video", stops: stops)
        videos[source.id] = capture
        videoCaptures.append(capture)
        return capture
    }

    func audio(for source: AudioSource) -> (any AudioCapture)? {
        let capture = FakeAudioCapture(name: "audio", stops: stops)
        audios[source.id] = capture
        audioCaptures.append(capture)
        return capture
    }

    func minecraftAudio(processID: Int32) -> (any AudioCapture)? {
        let capture = FakeAudioCapture(name: "audio", stops: stops)
        minecraftAudio = capture
        audioCaptures.append(capture)
        return capture
    }

    /// Whether any capture made so far still runs: a camera's light or macOS's recording indicator would be on.
    var anyRunning: Bool { videoCaptures.contains(where: \.isRunning) || audioCaptures.contains(where: \.isRunning) }
}

/// Records what the controller asked of the Save/Delete question instead of showing a panel.
@MainActor
final class FakeDecisionPresenter: RecordingDecisionPresenting {
    private(set) var presented: [ScreenRecordingController.Finished] = []
    private(set) var dismissals = 0
    private(set) var isShowing = false
    /// Runs as the question shows, so a test can see what the controller had done by then.
    var onPresent: (@MainActor (ScreenRecordingController) -> Void)?

    func present(for controller: ScreenRecordingController) {
        if let finished = controller.finished { presented.append(finished) }
        isShowing = true
        onPresent?(controller)
    }

    func dismiss() {
        dismissals += 1
        isShowing = false
    }
}

private struct Granted: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// Screen & System Audio Recording as the test sets it, everything else granted. Nothing asks the system, and the
/// test sees whether anything asked at all.
private final class ScreenRecordingPermission: PermissionProbing {
    private let screenRecording: Mutex<PermissionStatus>
    private let requests = Mutex(0)

    init(_ status: PermissionStatus) {
        screenRecording = Mutex(status)
    }

    func set(_ status: PermissionStatus) { screenRecording.withLock { $0 = status } }

    var requestCount: Int { requests.withLock { $0 } }

    func status(for permission: Permission) -> PermissionStatus {
        permission == .screenRecording ? screenRecording.withLock { $0 } : .granted
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        requests.withLock { $0 += 1 }
        return status(for: permission)
    }
}

/// How many times Add Source's listing finished.
@MainActor
private final class ListingCount {
    var finished = 0
}

@MainActor
private struct Harness {
    let directory: URL
    let factory = FakeFactory()
    /// The harness's own feeds, so nothing leaks into or out of the app's.
    let audio = InProcessAudio()
    let presenter = FakeDecisionPresenter()
    let controller: ScreenRecordingController
    let source: StaticMinecraftWindowSource
    let listings = ListingCount()

    /// `sourcesTake`: how long Minecraft's capture takes to start when the tool switches on, as ScreenCaptureKit's can
    /// on real hardware. `listingTakes`: how long Add Source's listing takes, and `listing` what it finds.
    /// `permissions`: what the permission center reads; everything is granted by default.
    init(minecraft: Bool = true, sourcesTake: Duration? = nil, listingTakes: Duration? = nil,
         listing: AvailableSources = AvailableSources(), permissions: any PermissionProbing = Granted()) {
        directory = FileManager.default.temporaryDirectory.appending(path: "stools-recording-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = MinecraftWindow(windowNumber: 42, processID: 4242, title: "Minecraft* 1.16.1", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        source = StaticMinecraftWindowSource(instances: minecraft ? [MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1))] : [])
        let locator = MinecraftLocator(source: source)
        locator.refresh()
        let services = ToolServices(
            settings: SettingsStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory)),
            displays: DisplayDirectory(), minecraft: locator, permissions: PermissionCenter(prober: permissions))
        let factory = factory
        factory.baseStartTakes = sourcesTake
        let listings = listings
        controller = ScreenRecordingController(
            services: services, makeFactory: { _ in factory },
            loadAvailable: { _ in
                if let listingTakes { try? await Task.sleep(for: listingTakes) }
                listings.finished += 1
                return listing
            },
            inProcessAudio: audio, decisionPresenter: presenter)
        var options = controller.options
        options.folderPath = directory.appending(path: "Movies").path
        options.canvas = .custom(PixelSize(width: 320, height: 180))
        options.frameRate = .fps30
        controller.options = options
    }

    func arm() async {
        controller.setEnabled(true)
        for _ in 0..<200 where !(controller.isEnabled && (factory.bases[42] != nil || controller.previewMessage != nil)) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// Records about `seconds` of a still base frame.
    func record(seconds: Double) async {
        pushFrame()
        await controller.startRecording()
        try? await Task.sleep(for: .seconds(seconds))
        await controller.stopRecording(explanation: nil)
    }

    /// A camera on the canvas and a microphone, beside Minecraft's picture and sound: two video and two audio sources.
    func addCameraAndMicrophone() {
        controller.updateLayout {
            $0.add(VideoSource(kind: .camera(CameraReference(uniqueID: "cam", name: "Cam")), frame: PixelRect(x: 0, y: 0, width: 50, height: 50), on: PixelSize(width: 320, height: 180)))
            $0.add(AudioSource(kind: .microphone(uniqueID: "mic"), name: "Mic"))
        }
    }

    /// One still frame from Minecraft's (fake) window.
    func pushFrame() {
        factory.bases[42]?.push(.frame(VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: 1, size: PixelSize(width: 320, height: 180)), hostTime: HostMediaClock().now())))
    }

    /// Waits (bounded, generously: arming and starting can take seconds while the whole suite runs) for `condition`,
    /// yielding between checks.
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    /// Off, the key switches the tool on and records at once; pressed again after a moment, it stops and asks.
    func recordByKey() async {
        controller.toggleRecording()
        _ = await waitUntil { controller.phase == .recording }
        pushFrame()
        try? await Task.sleep(for: .milliseconds(250))
        controller.toggleRecording()
        _ = await waitUntil { controller.phase == .deciding }
    }

    /// The recording folder's files, by name.
    func savedFileNames() -> [String] {
        let folder = URL(fileURLWithPath: controller.options.folderPath)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Screen Recording controller", .serialized) @MainActor
struct ScreenRecordingControllerTests {
    @Test func armingCapturesMinecraftAndEveryLayoutSource() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let micID = UUID()
        harness.controller.updateLayout {
            $0.add(VideoSource(kind: .camera(CameraReference(uniqueID: "cam", name: "Cam")), frame: PixelRect(x: 0, y: 0, width: 50, height: 50), on: PixelSize(width: 320, height: 180)))
            $0.add(AudioSource(id: micID, kind: .microphone(uniqueID: "mic"), name: "Mic"))
        }
        await harness.arm()
        #expect(harness.factory.bases[42] != nil)
        #expect(harness.factory.minecraftAudio != nil)
        #expect(harness.factory.videos.count == 1)
        #expect(harness.factory.audios[micID] != nil)
        #expect(harness.controller.previewMessage == nil)
        harness.controller.setEnabled(false)
    }

    /// Timer Overlay's alarm feed (spec 5.4.1, plan decision 3): armed, the rig listens to every feed; a recording
    /// gets the feed's track only when the feed wants recording as it starts.
    @Test(arguments: [true, false])
    func aFeedIsATrackOnlyWhenItWantsRecordingAtTheStart(wantsRecording: Bool) async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        harness.controller.options.askSaveDelete = false
        let feed = harness.audio.feed(named: "Timer alarm")
        feed.wantsRecording = wantsRecording
        await harness.arm()
        #expect(feed.hasListeners)
        await harness.record(seconds: 0.5)
        let file = try #require(harness.controller.lastSaved?.files.first ?? harness.controller.finished?.files.first)
        let titles = try await MovieInfo.load(file).audioTracks.map(\.title)
        #expect(titles.contains("Timer alarm") == wantsRecording)
        #expect(titles.first == "Mix")
        harness.controller.setEnabled(false)
        for _ in 0..<200 where feed.hasListeners { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!feed.hasListeners)
    }

    @Test func aFeedTurnedOnDuringARecordingWaitsForTheNextOne() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        harness.controller.options.askSaveDelete = false
        let feed = harness.audio.feed(named: "Timer alarm")
        await harness.arm()
        harness.factory.bases[42]?.push(.frame(VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: 1, size: PixelSize(width: 320, height: 180)), hostTime: HostMediaClock().now())))
        await harness.controller.startRecording()
        feed.wantsRecording = true
        try? await Task.sleep(for: .seconds(0.4))
        await harness.controller.stopRecording(explanation: nil)
        let file = try #require(harness.controller.lastSaved?.files.first ?? harness.controller.finished?.files.first)
        #expect(!(try await MovieInfo.load(file).audioTracks.map(\.title).contains("Timer alarm")))
        harness.controller.setEnabled(false)
    }

    @Test func withoutMinecraftOnlyAddedSourcesRun() async throws {
        let harness = Harness(minecraft: false)
        defer { harness.remove() }
        await harness.arm()
        #expect(harness.factory.bases.isEmpty)
        #expect(harness.controller.previewMessage?.contains("Open Minecraft") == true)
        harness.controller.setEnabled(false)
    }

    @Test func stoppingAsksThenSavesWithAName() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.arm()
        await harness.record(seconds: 0.5)
        #expect(harness.controller.phase == .deciding)
        let finished = try #require(harness.controller.finished)
        #expect(finished.files.count == 1 && finished.files[0].pathExtension == "mov")
        await harness.controller.save(name: "Seed 1")
        #expect(harness.controller.phase == .idle)
        let saved = try #require(harness.controller.lastSaved?.files.first)
        #expect(harness.controller.lastSaved?.problems == [])
        #expect(saved.lastPathComponent == "Seed 1.mp4")
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(!FileManager.default.fileExists(atPath: finished.files[0].path))
        #expect(harness.presenter.presented.count == 1 && harness.presenter.dismissals == 1)
        // Stopping a recording turns the tool off once it's saved.
        #expect(!harness.controller.isEnabled)
    }

    @Test func deleteRemovesTheRecording() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.arm()
        await harness.record(seconds: 0.3)
        let file = try #require(harness.controller.finished?.files.first)
        harness.controller.delete()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
    }

    @Test func withTheQuestionOffItSavesByDateAndTime() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.askSaveDelete = false
        harness.controller.options.fileType = .mov
        await harness.arm()
        await harness.record(seconds: 0.3)
        #expect(harness.controller.phase == .idle)
        let saved = try #require(harness.controller.lastSaved?.files.first)
        #expect(saved.pathExtension == "mov")
        #expect(saved.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}\.mov$"#, options: .regularExpression) != nil)
        // Saved without the question, and the tool off all the same.
        #expect(harness.presenter.presented.isEmpty)
        #expect(!harness.controller.isEnabled)
    }

    @Test func theTestRecordingIsSavedWithoutAsking() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        await harness.arm()
        harness.factory.bases[42]?.push(.frame(VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: 1, size: PixelSize(width: 320, height: 180)), hostTime: HostMediaClock().now())))
        let saved = await harness.controller.recordTest(for: .milliseconds(300))
        #expect(saved)
        #expect(harness.controller.options.askSaveDelete)
        #expect(harness.controller.phase == .idle)
        // The Prologue's test asks nothing and leaves the tool on, its sources running, so it can run again at once.
        #expect(harness.presenter.presented.isEmpty)
        #expect(harness.controller.isEnabled)
        #expect(harness.factory.bases[42]?.isRunning == true)
        let file = try #require(harness.controller.lastSaved?.files.first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        harness.controller.setEnabled(false)
    }

    @Test func theLayoutIsLockedWhileRecording() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.arm()
        harness.factory.bases[42]?.push(.frame(VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: 1), hostTime: HostMediaClock().now())))
        await harness.controller.startRecording()
        #expect(harness.controller.isLayoutLocked)
        harness.controller.updateLayout { $0.includesMinecraftAudio = false }
        #expect(harness.controller.layout.includesMinecraftAudio)
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
        harness.controller.setEnabled(false)
    }

    @Test func aClosedSourceIsNoted() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let id = UUID()
        harness.controller.updateLayout {
            $0.add(VideoSource(id: id, kind: .window(WindowReference(windowID: 9, appName: "Discord", title: "Call")), frame: PixelRect(x: 0, y: 0, width: 50, height: 50), on: PixelSize(width: 320, height: 180)))
        }
        await harness.arm()
        harness.factory.videos[id]?.push(.ended("gone"))
        for _ in 0..<100 where harness.controller.notes.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(harness.controller.notes == ["Discord \u{2014} Call closed; its place stays empty."])
        harness.controller.setEnabled(false)
    }

    @Test func theHotkeyArmsAndRecords() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.toggleRecording()
        for _ in 0..<200 where harness.controller.phase != .recording { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(harness.controller.isEnabled)
        #expect(harness.controller.phase == .recording)
        harness.factory.bases[42]?.push(.frame(VideoFrame(pixelBuffer: WriterFixture.makeFrame(index: 1), hostTime: HostMediaClock().now())))
        try await Task.sleep(for: .milliseconds(200))
        harness.controller.toggleRecording()
        for _ in 0..<400 where harness.controller.phase != .deciding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(harness.controller.phase == .deciding)
        harness.controller.delete()
        harness.controller.setEnabled(false)
    }
}

/// Screen Recording's one key and the question after a stop (spec 5.4.4, 6.1): the key turns recording on and off,
/// stopping asks for the name and Save or Delete, and once it's answered the tool is off. On fakes: no capture, no
/// window, no sound.
@Suite("Screen Recording's one key", .serialized) @MainActor
struct ScreenRecordingKeyTests {
    @Test func offTheKeySwitchesTheToolOnAndRecordsAtOnce() async throws {
        let harness = Harness()
        defer { harness.remove() }
        #expect(!harness.controller.isEnabled)
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(harness.controller.isEnabled)
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    @Test func whileRecordingTheKeyStopsAndAsksWithTheDateAndTimeOffered() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.recordByKey()
        #expect(harness.controller.phase == .deciding)
        let finished = try #require(harness.controller.finished)
        #expect(harness.presenter.presented == [finished])
        #expect(harness.presenter.isShowing)
        // The offered name is the one it was written under: its date and time.
        #expect(finished.name.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil)
        #expect(finished.files.map { $0.deletingPathExtension().lastPathComponent } == [finished.name])
        // Already off: the stop switched it off before the question came up.
        #expect(!harness.controller.isEnabled)
        harness.controller.delete()
    }

    @Test func savingKeepsTheFileUnderItsNameAndTurnsTheToolOff() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        await harness.recordByKey()
        await harness.controller.save(name: "Any% 14:02")
        #expect(harness.savedFileNames() == ["Any% 14-02.mov"])
        #expect(harness.controller.lastSaved?.files.map(\.lastPathComponent) == ["Any% 14-02.mov"])
        #expect(harness.presenter.dismissals == 1 && !harness.presenter.isShowing)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
    }

    @Test func deletingRemovesTheFileAndTurnsTheToolOff() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.recordByKey()
        let file = try #require(harness.controller.finished?.files.first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        harness.controller.delete()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(harness.savedFileNames().isEmpty)
        #expect(harness.controller.lastSaved == nil)
        #expect(harness.presenter.dismissals == 1)
        #expect(!harness.controller.isEnabled)
    }

    /// Esc cancels the naming: the recording is saved under the offered date-and-time name, so nothing is lost.
    @Test func cancelingSavesUnderTheOfferedName() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        await harness.recordByKey()
        let finished = try #require(harness.controller.finished)
        let draft = RecordingDecisionDraft(name: "typed but not saved")
        draft.cancel(harness.controller)
        #expect(await harness.waitUntil { harness.controller.lastSaved != nil })
        #expect(harness.savedFileNames() == ["\(finished.name).mov"])
        #expect(harness.presenter.dismissals == 1)
        #expect(await harness.waitUntil { !harness.controller.isEnabled })
    }

    /// Inside the Delete confirmation, Esc steps back to the question; it neither deletes nor saves.
    @Test func escInTheDeleteConfirmationStepsBack() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.recordByKey()
        let draft = RecordingDecisionDraft(name: try #require(harness.controller.finished).name)
        draft.confirmsDelete = true
        draft.cancel(harness.controller)
        #expect(!draft.confirmsDelete)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.controller.phase == .deciding)
        #expect(harness.controller.lastSaved == nil)
        harness.controller.delete()
    }

    /// The page's Stop asks the same question, and the tool goes off after it all the same.
    @Test func thePagesStopAsksAndTurnsTheToolOffToo() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.arm()
        await harness.record(seconds: 0.3)
        #expect(harness.controller.phase == .deciding)
        #expect(harness.presenter.presented.count == 1)
        await harness.controller.cancelDecision()
        #expect(harness.controller.lastSaved?.files.count == 1)
        #expect(!harness.controller.isEnabled)
    }

    /// Pressed while the question waits, the key brings it forward again and changes nothing else.
    @Test func theKeyWhileItAsksBringsTheQuestionBack() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.recordByKey()
        harness.controller.toggleRecording()
        #expect(harness.presenter.presented.count == 2)
        #expect(harness.controller.phase == .deciding)
        harness.controller.delete()
    }

    /// A second answer, from a double click or quitting while it saves, finds nothing to do.
    @Test func aSecondAnswerDoesNothing() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        await harness.recordByKey()
        async let first: Void = harness.controller.save(name: "One")
        async let second: Void = harness.controller.save(name: "Two")
        _ = await (first, second)
        harness.controller.delete()
        let saved = harness.savedFileNames()
        #expect(saved == ["One.mov"] || saved == ["Two.mov"])
    }

    /// Through the app's switch when it has one, so the sidebar and Home follow: once, at the stop, and not again when
    /// the question is answered.
    @Test func theToolGoesOffThroughTheAppsSwitch() async throws {
        let harness = Harness()
        defer { harness.remove() }
        var requests = 0
        harness.controller.requestDisable = { [controller = harness.controller] in
            requests += 1
            controller.setEnabled(false)
        }
        await harness.recordByKey()
        #expect(requests == 1)
        #expect(!harness.controller.isEnabled)
        harness.controller.delete()
        #expect(requests == 1)
        #expect(!harness.controller.isEnabled)
    }

    /// ducky: "stopping recording turns off the tool". The press that stops a recording switches the tool off right
    /// then, and every source stops with it (a camera's light and macOS's recording indicator go out); the file is
    /// finished, and only then does the question come up, for that finished file.
    @Test func theStopTurnsTheToolAndEverySourceOffBeforeTheQuestion() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.addCameraAndMicrophone()
        var whenAsked: (isEnabled: Bool, anySourceRunning: Bool, fileOpens: Bool)?
        harness.presenter.onPresent = { [factory = harness.factory] controller in
            let file = controller.finished?.files.first
            whenAsked = (controller.isEnabled, factory.anyRunning, file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(harness.factory.videoCaptures.count == 2 && harness.factory.audioCaptures.count == 2)
        #expect(harness.factory.videoCaptures.allSatisfy(\.isRunning) && harness.factory.audioCaptures.allSatisfy(\.isRunning))
        harness.pushFrame()
        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.controller.toggleRecording() == .stopped)
        // The switch goes off with the press, before anything is finished or asked.
        #expect(!harness.controller.isEnabled)
        #expect(harness.presenter.presented.isEmpty)
        #expect(await harness.waitUntil { harness.controller.phase == .deciding })
        let asked = try #require(whenAsked)
        #expect(!asked.isEnabled)
        #expect(!asked.anySourceRunning)
        #expect(asked.fileOpens)
        let file = try #require(harness.controller.finished?.files.first)
        #expect(try await MovieInfo.load(file).videoSampleCount > 0)
        harness.controller.delete()
    }

    /// The video sources stop at the press: the clock has stopped, so they would add nothing. The sound's sources run
    /// for the moment the recording's last samples take to arrive, so the file keeps the sound up to the press, and
    /// stop before the question.
    @Test func theVideoStopsAtThePressAndTheSoundOnceItsLastSamplesAreIn() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.addCameraAndMicrophone()
        await harness.recordByKey()
        let stops = harness.factory.stops.all
        #expect(stops.sorted() == ["audio", "audio", "video", "video"])
        #expect(stops.prefix(2) == ["video", "video"])
        harness.controller.delete()
    }

    /// The tool is off while the question waits, and answering it only saves or deletes: switched back on by hand in
    /// the meantime, it stays on.
    @Test(arguments: [true, false])
    func theAnswerOnlySavesOrDeletes(saves: Bool) async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        await harness.recordByKey()
        let file = try #require(harness.controller.finished?.files.first)
        #expect(!harness.controller.isEnabled)
        harness.controller.setEnabled(true)
        if saves {
            await harness.controller.save(name: "Seed 7")
            #expect(harness.savedFileNames() == ["Seed 7.mov"])
        } else {
            harness.controller.delete()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(harness.savedFileNames().isEmpty)
        }
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.isEnabled)
        harness.controller.setEnabled(false)
    }

    /// While the question waits, the key brings it back ("Save or delete the last recording first") and starts nothing:
    /// the tool stays off and no source starts, however long it waits. Once it's answered, the key records again.
    @Test func theKeyWhileTheQuestionWaitsStartsNothing() async throws {
        let harness = Harness()
        defer { harness.remove() }
        await harness.recordByKey()
        let armings = harness.factory.baseCount
        #expect(harness.controller.toggleRecording() == .awaitingDecision)
        #expect(harness.controller.toggleRecording() == .awaitingDecision)
        #expect(harness.presenter.presented.count == 3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.controller.phase == .deciding)
        #expect(!harness.controller.isEnabled)
        #expect(harness.factory.baseCount == armings)
        #expect(!harness.factory.anyRunning)
        harness.controller.delete()
        #expect(!harness.controller.isEnabled)
        await harness.recordByKey()
        #expect(harness.factory.baseCount == armings + 1)
        harness.controller.delete()
    }

    /// Quitting while the question waits keeps the recording under its date-and-time name, without asking.
    @Test func quittingWhileTheQuestionWaitsSavesUnderTheDateAndTime() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        await harness.recordByKey()
        let name = try #require(harness.controller.finished?.name)
        await harness.controller.finishForQuit()
        #expect(harness.savedFileNames() == ["\(name).mov"])
        #expect(harness.controller.lastSaved?.files.map(\.lastPathComponent) == ["\(name).mov"])
        #expect(harness.presenter.dismissals == 1 && !harness.presenter.isShowing)
        #expect(harness.controller.phase == .idle)
    }

    /// Quitting just after the stop, while the file is still being finished, saves it the same way once it's finished,
    /// and the question never comes up.
    @Test func quittingWhileTheRecordingFinishesSavesItWithoutAsking() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        harness.pushFrame()
        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.controller.toggleRecording() == .stopped)
        #expect(harness.controller.phase == .finishing)
        await harness.controller.finishForQuit()
        #expect(harness.presenter.presented.isEmpty)
        let saved = harness.savedFileNames()
        #expect(saved.count == 1)
        #expect(saved.first?.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}\.mov$"#, options: .regularExpression) != nil)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
    }

    /// The key turns recording off before it began, too: canceling the countdown switches the tool off.
    @Test func cancelingTheCountdownTurnsTheToolOff() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.countdown = .threeSeconds
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .countingDown(3) })
        #expect(harness.controller.isEnabled)
        harness.controller.toggleRecording()
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        #expect(harness.presenter.presented.isEmpty)
    }

    /// Off, the key switches the tool on and starts at once, but writing begins only once the sources run. A second
    /// press in that moment cancels the start, as one during a countdown does: nothing is written, nothing is asked,
    /// and the tool is off. (It used to start a second recording, and one of the two kept writing unseen.)
    @Test func aSecondPressWhileItStartsCancelsItAndWritesNothing() async throws {
        let harness = Harness(sourcesTake: .milliseconds(300))
        defer { harness.remove() }
        #expect(harness.controller.toggleRecording() == .starting(waitsForSources: true))
        #expect(harness.controller.phase == .starting)
        #expect(harness.controller.isEnabled)
        #expect(harness.controller.isLayoutLocked)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.controller.toggleRecording() == .canceled)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        // Long after the sources would have started, still nothing.
        try await Task.sleep(for: .milliseconds(700))
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        #expect(harness.savedFileNames().isEmpty)
        #expect(harness.presenter.presented.isEmpty)
    }

    /// One press while the sources take their time records exactly once, and the next press stops that recording.
    @Test func onePressWhileTheSourcesTakeTheirTimeRecordsOnce() async throws {
        let harness = Harness(sourcesTake: .milliseconds(300))
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        #expect(harness.controller.toggleRecording() == .starting(waitsForSources: true))
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        harness.pushFrame()
        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.controller.toggleRecording() == .stopped)
        #expect(await harness.waitUntil { harness.controller.phase == .deciding })
        #expect(harness.controller.finished?.files.count == 1)
        #expect(harness.savedFileNames().count == 1)
        harness.controller.delete()
        #expect(harness.savedFileNames().isEmpty)
        #expect(!harness.controller.isEnabled)
    }

    /// After a canceled start, the next press switches the tool on and records again.
    @Test func aPressAfterACanceledStartRecords() async throws {
        let harness = Harness(sourcesTake: .milliseconds(200))
        defer { harness.remove() }
        harness.controller.toggleRecording()
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.controller.toggleRecording() == .canceled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.controller.toggleRecording() == .starting(waitsForSources: true))
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(harness.controller.isEnabled)
        harness.pushFrame()
        try await Task.sleep(for: .milliseconds(250))
        await harness.controller.stopRecording(explanation: nil)
        #expect(harness.savedFileNames().count == 1)
        harness.controller.delete()
    }

    /// Switching the tool off while it starts ends the start too.
    @Test func switchingOffWhileItStartsWritesNothing() async throws {
        let harness = Harness(sourcesTake: .milliseconds(300))
        defer { harness.remove() }
        harness.controller.toggleRecording()
        try await Task.sleep(for: .milliseconds(50))
        harness.controller.setEnabled(false)
        #expect(harness.controller.phase == .idle)
        try await Task.sleep(for: .milliseconds(600))
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        #expect(harness.savedFileNames().isEmpty)
    }

    /// What each press reports, for the confirmation over the game.
    @Test func eachPressSaysWhatItDid() async throws {
        let harness = Harness()
        defer { harness.remove() }
        #expect(harness.controller.toggleRecording() == .starting(waitsForSources: true))
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        harness.pushFrame()
        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.controller.toggleRecording() == .stopped)
        #expect(await harness.waitUntil { harness.controller.phase == .deciding })
        #expect(harness.controller.toggleRecording() == .awaitingDecision)
        harness.controller.delete()
        harness.controller.options.countdown = .threeSeconds
        #expect(harness.controller.toggleRecording() == .countdown(seconds: 3))
        #expect(await harness.waitUntil { harness.controller.phase == .countingDown(3) })
        #expect(harness.controller.toggleRecording() == .canceled)
        #expect(!harness.controller.isEnabled)
    }

    /// Without Screen & System Audio Recording there is nothing to record but a blank canvas, and arming would bring up
    /// macOS's prompt over the game. The key starts nothing, the tool stays off, nothing asks for the permission, and
    /// the press says why.
    @Test func withoutScreenRecordingPermissionTheKeyStartsNothing() async throws {
        let permission = ScreenRecordingPermission(.denied)
        let harness = Harness(permissions: permission)
        defer { harness.remove() }
        #expect(harness.controller.toggleRecording() == .needsPermission)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.factory.bases.isEmpty)
        #expect(harness.savedFileNames().isEmpty)
        #expect(harness.presenter.presented.isEmpty)
        #expect(permission.requestCount == 0)
        #expect(harness.controller.screenRecordingPermission == .denied)
    }

    /// Switched on by hand without the permission, the key and Record still write nothing, and the tool stays on.
    @Test func withoutScreenRecordingPermissionRecordWritesNothing() async throws {
        let permission = ScreenRecordingPermission(.denied)
        let harness = Harness(permissions: permission)
        defer { harness.remove() }
        await harness.arm()
        harness.pushFrame()
        #expect(harness.controller.toggleRecording() == .needsPermission)
        await harness.controller.startRecording()
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.isEnabled)
        #expect(!(await harness.controller.recordTest(for: .milliseconds(100))))
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.savedFileNames().isEmpty)
        #expect(permission.requestCount == 0)
        harness.controller.setEnabled(false)
    }

    /// The permission is read at the press, so allowing it in System Settings counts at once.
    @Test func allowingThePermissionCountsAtTheNextPress() async throws {
        let permission = ScreenRecordingPermission(.denied)
        let harness = Harness(permissions: permission)
        defer { harness.remove() }
        #expect(harness.controller.toggleRecording() == .needsPermission)
        permission.set(.granted)
        #expect(harness.controller.toggleRecording() == .starting(waitsForSources: true))
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(harness.controller.screenRecordingPermission == .granted)
        harness.pushFrame()
        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.controller.toggleRecording() == .stopped)
        #expect(await harness.waitUntil { harness.controller.phase == .deciding })
        harness.controller.delete()
        #expect(!harness.controller.isEnabled)
    }

    /// Quitting mid-recording keeps it under its date-and-time name without showing the question.
    @Test func quittingSavesWithoutAsking() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.fileType = .mov
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        harness.pushFrame()
        try await Task.sleep(for: .milliseconds(250))
        await harness.controller.finishForQuit()
        #expect(harness.presenter.presented.isEmpty)
        #expect(harness.savedFileNames().count == 1)
        #expect(!harness.controller.isEnabled)
    }
}

/// "Recording started" means it: a start the key made is reported once the writer has put its first frame in the file,
/// not at the press (spec 5.4.4). The session's clock is fired by hand here, so the test decides when that frame is
/// written.
@Suite("Screen Recording's first frame", .serialized) @MainActor
struct ScreenRecordingFirstFrameTests {
    /// Off, the press switches the tool on and its sources start, so it says the start waits for them. Nothing is
    /// reported, and the recording isn't under way, until the first frame is in the file.
    @Test func aStartIsReportedOnlyOnceItsFirstFrameIsInTheFile() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let driver = ManualTickDriver()
        harness.controller.makeTickDriver = { driver }
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        #expect(harness.controller.toggleRecording() == .starting(waitsForSources: true))
        // The writer's clock runs once the sources do, but no frame is written until it ticks.
        #expect(await harness.waitUntil { driver.isRunning })
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.controller.phase == .starting)
        #expect(!harness.controller.isRecording)
        #expect(outcomes.isEmpty)
        harness.pushFrame()
        driver.fire()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(outcomes == [.started])
        await harness.controller.stopRecording(explanation: nil)
        let file = try #require(harness.controller.finished?.files.first)
        #expect(try await MovieInfo.load(file).videoSampleCount >= 1)
        harness.controller.delete()
        #expect(outcomes == [.started])
    }

    /// Already armed (switched on by hand), the press says writing begins at once; it's still reported only once the
    /// first frame is in.
    @Test func anArmedToolSaysItWritesAtOnce() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let driver = ManualTickDriver()
        harness.controller.makeTickDriver = { driver }
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        await harness.arm()
        harness.pushFrame()
        #expect(harness.controller.toggleRecording() == .starting(waitsForSources: false))
        #expect(await harness.waitUntil { driver.isRunning })
        #expect(outcomes.isEmpty)
        driver.fire()
        #expect(await harness.waitUntil { outcomes == [.started] })
        #expect(harness.controller.phase == .recording)
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    /// A press after the writer started but before its first frame cancels the start like any other: the file it
    /// opened is removed, nothing is asked or reported, and the tool is off.
    @Test func aPressBeforeTheFirstFrameCancelsAndLeavesNoFile() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let driver = ManualTickDriver()
        harness.controller.makeTickDriver = { driver }
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { driver.isRunning })
        #expect(await harness.waitUntil { !harness.savedFileNames().isEmpty })
        #expect(harness.controller.toggleRecording() == .canceled)
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        #expect(!driver.isRunning)
        #expect(await harness.waitUntil { harness.savedFileNames().isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.savedFileNames().isEmpty)
        #expect(harness.presenter.presented.isEmpty)
        #expect(outcomes.isEmpty)
        #expect(!harness.factory.anyRunning)
    }

    /// A disk too full to record on stops the writer at its first frame, so the recording never starts: the start
    /// ends with nothing left behind, the page says why, nothing is asked, and the tool is off. The key hears why, for
    /// its line over the game.
    @Test func aFullDiskEndsTheStartWithNothingLeftBehind() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.freeSpace = FakeFreeSpace(100 * 1_048_576)
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        harness.controller.toggleRecording()
        #expect(harness.controller.phase == .starting)
        #expect(await harness.waitUntil { harness.controller.phase == .idle && !harness.controller.isEnabled })
        #expect(outcomes == [.failed("the disk is almost full")])
        #expect(harness.controller.notes == ["The recording couldn\u{2019}t start: the disk is almost full."])
        #expect(await harness.waitUntil { harness.savedFileNames().isEmpty })
        #expect(harness.presenter.presented.isEmpty)
        #expect(harness.controller.finished == nil)
    }

    /// A recordings folder that can't be made or written to fails the start as the writer opens its file: the key
    /// hears why in a few words, the page says more, and the tool is off.
    @Test func anUnwritableFolderEndsTheStartAndSaysWhy() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let blocker = harness.directory.appending(path: "not a folder")
        try Data().write(to: blocker)
        harness.controller.options.folderPath = blocker.appending(path: "Movies").path
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { !outcomes.isEmpty })
        #expect(outcomes == [.failed("the recordings folder can\u{2019}t be written to")])
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        #expect(harness.controller.notes.count == 1)
        #expect(harness.controller.notes.first?.hasPrefix("The recording couldn\u{2019}t start: ") == true)
        #expect(harness.presenter.presented.isEmpty)
    }

    /// A first frame that never reaches the file (an encoder that never takes one) doesn't leave the start hanging:
    /// after a while it ends, says why, and leaves nothing behind.
    @Test func aFirstFrameThatNeverComesEndsTheStart() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let driver = ManualTickDriver()
        harness.controller.makeTickDriver = { driver }
        harness.controller.firstFrameTimeout = .milliseconds(300)
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { driver.isRunning })
        #expect(outcomes.isEmpty)
        #expect(await harness.waitUntil { !outcomes.isEmpty })
        #expect(outcomes == [.failed("the video encoder didn\u{2019}t respond")])
        #expect(harness.controller.phase == .idle)
        #expect(!harness.controller.isEnabled)
        #expect(!driver.isRunning)
        #expect(await harness.waitUntil { harness.savedFileNames().isEmpty })
    }

    /// Record on the page says why on the page; the line over the game is the key's alone.
    @Test func thePagesFailedStartReportsNothingOverTheGame() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.freeSpace = FakeFreeSpace(100 * 1_048_576)
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        await harness.controller.startRecording()
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.notes == ["The recording couldn\u{2019}t start: the disk is almost full."])
        #expect(outcomes.isEmpty)
    }

    /// With a countdown, the press says so, and the start is reported once the countdown has run and the first frame
    /// is in.
    @Test func aCountdownsStartIsReportedOnceItWrites() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.controller.options.countdown = .threeSeconds
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        #expect(harness.controller.toggleRecording() == .countdown(seconds: 3))
        #expect(await harness.waitUntil { harness.controller.phase == .countingDown(1) })
        #expect(outcomes.isEmpty)
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(outcomes == [.started])
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    /// Record on the page returns once the recording writes; nothing is reported for the game's line, which is the
    /// key's.
    @Test func thePagesRecordReturnsOnceItWritesAndReportsNothing() async throws {
        let harness = Harness()
        defer { harness.remove() }
        var outcomes: [ScreenRecordingController.KeyStartOutcome] = []
        harness.controller.keyStartEnded = { outcomes.append($0) }
        harness.controller.setEnabled(true)
        await harness.controller.startRecording()
        #expect(harness.controller.phase == .recording)
        #expect(outcomes.isEmpty)
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
        #expect(outcomes.isEmpty)
    }
}

/// The press-to-first-frame delay, kept short (spec 5.4.4): switching the tool on with the key starts its sources
/// together, doesn't wait for Add Source's listing unless a window source needs it, and writes as soon as Minecraft's
/// first frame is in, so the recording's first frame shows the game.
@Suite("Screen Recording's start, quickly", .serialized) @MainActor
struct ScreenRecordingQuickStartTests {
    /// Add Source's listing (ScreenCaptureKit's window list, the cameras and microphones) can take a while; a start
    /// with no window source records without waiting for it, and the listing still arrives for the page.
    @Test func theListingDoesntHoldUpAStart() async throws {
        let harness = Harness(listingTakes: .seconds(2))
        defer { harness.remove() }
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(harness.listings.finished == 0)
        #expect(await harness.waitUntil { harness.listings.finished == 1 })
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    /// A window source's window is found again in the listing (its number changes when the window is reopened), so a
    /// layout with one still waits for it, and records the window it found.
    @Test func aWindowSourceStillWaitsForTheListingToFindItsWindow() async throws {
        var listing = AvailableSources()
        listing.windows = [WindowReference(windowID: 77, appName: "Discord", bundleID: "com.hnc.Discord", title: "Call")]
        let harness = Harness(listingTakes: .milliseconds(300), listing: listing)
        defer { harness.remove() }
        harness.controller.updateLayout {
            $0.add(VideoSource(kind: .window(WindowReference(windowID: 9, appName: "Discord", bundleID: "com.hnc.Discord", title: "Call")),
                               frame: PixelRect(x: 0, y: 0, width: 50, height: 50), on: PixelSize(width: 320, height: 180)))
        }
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        #expect(harness.listings.finished >= 1)
        #expect(harness.factory.capturedWindowIDs.first == 77)
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    /// Minecraft's capture runs a moment before its first frame arrives. The start waits for that frame, so the file
    /// doesn't open on a black canvas, and writes as soon as it's in.
    @Test func theRecordingWaitsForMinecraftsFirstFrame() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.factory.baseSendsFirstFrame = false
        harness.controller.minecraftFrameWait = .seconds(10)
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.factory.bases[42]?.isRunning == true })
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.controller.phase == .starting)
        #expect(harness.savedFileNames().isEmpty)
        harness.pushFrame()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    /// A Minecraft capture that sends nothing holds the start only for a moment (half a second in sTools), then the
    /// recording starts without it and its picture joins when it comes.
    @Test func aSilentMinecraftCaptureHoldsTheStartBriefly() async throws {
        let harness = Harness()
        defer { harness.remove() }
        #expect(harness.controller.minecraftFrameWait == .milliseconds(500))
        harness.factory.baseSendsFirstFrame = false
        harness.controller.minecraftFrameWait = .milliseconds(300)
        let pressed = ContinuousClock.now
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        let waited = ContinuousClock.now - pressed
        #expect(waited >= .milliseconds(300))
        #expect(waited < .seconds(5))
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }
}

/// Each start is timed from the press to its first frame, and the timings go to the log for Copy Diagnostics, so a real
/// press on ducky's Mac shows where any delay comes from (spec 5.4.4).
@Suite("Screen Recording's start timings", .serialized) @MainActor
struct ScreenRecordingStartTimingTests {
    /// Already armed, with Minecraft's frame in, the writer opens right after the press: nothing waits for the sources
    /// (they take 3 s to start here) or for Minecraft's frame (a wait of up to 10 s here), and the encoder and Core
    /// Image were readied while the tool was armed. The bounds sit far below those waits, since the whole suite keeps
    /// the main thread busy; the first frame's own wait is the encoder's, which is only logged.
    @Test func anArmedToolOpensItsFileRightAfterThePress() async throws {
        let harness = Harness(sourcesTake: .seconds(3))
        defer { harness.remove() }
        harness.controller.minecraftFrameWait = .seconds(10)
        await harness.arm()
        #expect(await harness.waitUntil { harness.factory.bases[42]?.isRunning == true && harness.controller.isWarmedUp })
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        let timings = try #require(harness.controller.lastStartTimings)
        #expect(!timings.switchedOn)
        #expect(timings.toSources < .milliseconds(1500), "\(timings.summary)")
        #expect(timings.toWriter < .seconds(2), "\(timings.summary)")
        #expect(timings.toWriter <= timings.toFirstFrame)
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    /// The timings add up in order: the sources, Minecraft's first frame, the writer's file, the first frame in it.
    @Test func eachStartsTimingsAddUp() async throws {
        let harness = Harness(sourcesTake: .milliseconds(200))
        defer { harness.remove() }
        harness.controller.toggleRecording()
        #expect(await harness.waitUntil { harness.controller.phase == .recording })
        let timings = try #require(harness.controller.lastStartTimings)
        #expect(timings.switchedOn)
        #expect(timings.toSources >= .milliseconds(200))
        #expect(timings.toSources <= timings.toMinecraftFrame)
        #expect(timings.toMinecraftFrame <= timings.toWriter)
        #expect(timings.toWriter <= timings.toFirstFrame)
        #expect(timings.summary.hasPrefix("Recording started "))
        #expect(timings.summary.contains("after the press"))
        await harness.controller.stopRecording(explanation: nil)
        harness.controller.delete()
    }

    /// Switching the tool on readies the encoder and Core Image alongside the sources, and switching it off lets go
    /// of what was readied.
    @Test func armingWarmsUpAndSwitchingOffLetsGo() async throws {
        let harness = Harness()
        defer { harness.remove() }
        #expect(!harness.controller.isWarmedUp)
        await harness.arm()
        #expect(await harness.waitUntil { harness.controller.isWarmedUp })
        harness.controller.setEnabled(false)
        #expect(await harness.waitUntil { !harness.controller.isWarmedUp })
    }

    /// The timings read as one line, in milliseconds.
    @Test func theSummaryReadsInMilliseconds() {
        let timings = ScreenRecordingController.StartTimings(
            switchedOn: true, countdownSeconds: 0, toSources: .milliseconds(312), toMinecraftFrame: .milliseconds(340),
            toWriter: .milliseconds(349), toFirstFrame: .milliseconds(362))
        #expect(timings.summary == "Recording started 362 ms after the press (switched on): sources 312 ms, Minecraft\u{2019}s first frame 28 ms, writer 9 ms, first frame 13 ms.")
        let counted = ScreenRecordingController.StartTimings(
            switchedOn: false, countdownSeconds: 3, toSources: .milliseconds(0), toMinecraftFrame: .milliseconds(3001),
            toWriter: .milliseconds(3008), toFirstFrame: .milliseconds(3020))
        #expect(counted.summary == "Recording started 3020 ms after the press (armed, after a 3 s countdown): sources 0 ms, Minecraft\u{2019}s first frame 1 ms, writer 7 ms, first frame 12 ms.")
    }
}
