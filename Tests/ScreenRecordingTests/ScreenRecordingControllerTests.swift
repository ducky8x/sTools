import CoreGraphics
import Foundation
import Testing
@testable import ScreenRecording
@testable import STPlatform

@MainActor
private final class FakeFactory: CaptureFactory {
    var bases: [UInt32: FakeVideoCapture] = [:]
    var videos: [UUID: FakeVideoCapture] = [:]
    var audios: [UUID: FakeAudioCapture] = [:]
    var minecraftAudio: FakeAudioCapture?

    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? {
        let capture = FakeVideoCapture()
        bases[minecraftWindowID] = capture
        return capture
    }

    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)? {
        let capture = FakeVideoCapture()
        videos[source.id] = capture
        return capture
    }

    func audio(for source: AudioSource) -> (any AudioCapture)? {
        let capture = FakeAudioCapture()
        audios[source.id] = capture
        return capture
    }

    func minecraftAudio(processID: Int32) -> (any AudioCapture)? {
        let capture = FakeAudioCapture()
        minecraftAudio = capture
        return capture
    }
}

/// Records what the controller asked of the Save/Delete question instead of showing a panel.
@MainActor
final class FakeDecisionPresenter: RecordingDecisionPresenting {
    private(set) var presented: [ScreenRecordingController.Finished] = []
    private(set) var dismissals = 0
    private(set) var isShowing = false

    func present(for controller: ScreenRecordingController) {
        if let finished = controller.finished { presented.append(finished) }
        isShowing = true
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

@MainActor
private struct Harness {
    let directory: URL
    let factory = FakeFactory()
    /// The harness's own feeds, so nothing leaks into or out of the app's.
    let audio = InProcessAudio()
    let presenter = FakeDecisionPresenter()
    let controller: ScreenRecordingController
    let source: StaticMinecraftWindowSource

    init(minecraft: Bool = true) {
        directory = FileManager.default.temporaryDirectory.appending(path: "stools-recording-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = MinecraftWindow(windowNumber: 42, processID: 4242, title: "Minecraft* 1.16.1", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        source = StaticMinecraftWindowSource(instances: minecraft ? [MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1))] : [])
        let locator = MinecraftLocator(source: source)
        locator.refresh()
        let services = ToolServices(
            settings: SettingsStore(directory: directory.appending(path: "settings", directoryHint: .isDirectory)),
            displays: DisplayDirectory(), minecraft: locator, permissions: PermissionCenter(prober: Granted()))
        let factory = factory
        controller = ScreenRecordingController(
            services: services, makeFactory: { _ in factory }, loadAvailable: { _ in AvailableSources() }, inProcessAudio: audio,
            decisionPresenter: presenter)
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
        harness.controller.setEnabled(false)
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
        harness.controller.setEnabled(false)
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
        // Saved without the question.
        #expect(harness.presenter.presented.isEmpty)
        harness.controller.setEnabled(false)
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
        // The Prologue's test asks nothing.
        #expect(harness.presenter.presented.isEmpty)
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

