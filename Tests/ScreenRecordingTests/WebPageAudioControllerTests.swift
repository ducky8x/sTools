import CoreGraphics
import Foundation
import Testing
@testable import ScreenRecording
@testable import STPlatform

/// What a rig asks the factory for when the layout has web pages, on fakes: no capture, no window, no sound, no
/// permission, and a display that is nowhere on a screen.
@MainActor
private final class WebAudioFactory: CaptureFactory {
    private(set) var webCaptures: [FakeAudioCapture] = []
    private(set) var failingCaptures = 0
    /// The next capture the factory makes can't start.
    var nextCaptureFailsToStart = false

    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func audio(for source: AudioSource) -> (any AudioCapture)? { nil }
    func minecraftAudio(processID: Int32) -> (any AudioCapture)? { nil }

    func webPageAudio() -> (any AudioCapture)? {
        if nextCaptureFailsToStart {
            nextCaptureFailsToStart = false
            failingCaptures += 1
            return FailingAudioCapture()
        }
        let capture = FakeAudioCapture()
        webCaptures.append(capture)
        return capture
    }

    var running: [FakeAudioCapture] { webCaptures.filter(\.isRunning) }
}

private final class FailingAudioCapture: AudioCapture, @unchecked Sendable {
    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws { throw CaptureError.unavailable("sTools isn\u{2019}t allowed to record app audio.") }
    func stop() async {}
}

private struct AlwaysGranted: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

@MainActor
private struct Rig {
    let directory: URL
    let factory = WebAudioFactory()
    let controller: ScreenRecordingController

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "stools-web-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = CGRect(x: -9000, y: -9000, width: 1920, height: 1080)
        let display = DisplayInfo(id: 9000, name: "Off screen", frame: frame, bounds: frame, backingScale: 1,
                                  pixelSize: CGSize(width: 1920, height: 1080), isMain: true)
        let services = ToolServices(
            settings: SettingsStore(directory: directory),
            displays: DisplayDirectory(screenProvider: { [display] }),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])),
            permissions: PermissionCenter(prober: AlwaysGranted()))
        let factory = factory
        controller = ScreenRecordingController(services: services, makeFactory: { _ in factory }, loadAvailable: { _ in AvailableSources() })
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func arm() async -> Bool {
        controller.setEnabled(true)
        return await waitUntil { controller.sourcesAreReady }
    }
}

/// Waits (bounded, on a clock a Mac sleep doesn't use up, and generously) for `condition`, yielding between checks.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + .seconds(20)
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("The web pages' sound, armed with the sources", .serialized) @MainActor
struct WebPageAudioControllerTests {
    @Test func aWebPageArmsOneCaptureOfItsSoundAndSwitchingOffStopsIt() async throws {
        let rig = Rig()
        defer { rig.remove() }
        rig.controller.addBrowserSource(url: "twitch.tv/someone")
        #expect(await rig.arm())
        #expect(rig.factory.webCaptures.count == 1)
        #expect(rig.factory.running.count == 1, "armed with the source")
        rig.controller.setEnabled(false)
        #expect(await waitUntil { rig.factory.running.isEmpty }, "switched off, nothing is left tapping")
    }

    @Test func severalWebPagesShareOneCapture() async throws {
        let rig = Rig()
        defer { rig.remove() }
        rig.controller.addBrowserSource(url: "twitch.tv/someone")
        rig.controller.addBrowserSource(url: "example.org")
        #expect(await rig.arm())
        #expect(rig.factory.webCaptures.count == 1, "the pages' sound can't be told apart, so it is one tap, one track")
        rig.controller.setEnabled(false)
        #expect(await waitUntil { rig.factory.running.isEmpty })
    }

    @Test func withoutAWebPageThereIsNoCapture() async throws {
        let rig = Rig()
        defer { rig.remove() }
        rig.controller.addVideo(.camera(CameraReference(uniqueID: "cam", name: "Cam")), contentSize: PixelSize(width: 640, height: 360))
        #expect(await rig.arm())
        #expect(rig.factory.webCaptures.isEmpty)
        rig.controller.setEnabled(false)
    }

    /// A change to the sources restarts them (spec 5.4.4): the switch, the first page and the last page's removal all
    /// change what is tapped, and the capture that is no longer wanted is stopped.
    @Test func theSwitchRestartsTheSourcesAndTheOldCaptureIsStopped() async throws {
        let rig = Rig()
        defer { rig.remove() }
        rig.controller.addBrowserSource(url: "twitch.tv/someone")
        #expect(await rig.arm())
        let first = try #require(rig.factory.webCaptures.first)
        rig.controller.updateLayout { $0.includesWebPageAudio = false }
        #expect(await waitUntil { !first.isRunning }, "the switch took the tap down")
        #expect(await waitUntil { rig.controller.sourcesAreReady })
        #expect(rig.factory.webCaptures.count == 1, "none was made while the switch was off")
        rig.controller.updateLayout { $0.includesWebPageAudio = true }
        #expect(await waitUntil { rig.factory.webCaptures.count == 2 && rig.factory.running.count == 1 })
        rig.controller.setEnabled(false)
        #expect(await waitUntil { rig.factory.running.isEmpty })
    }

    @Test func removingTheLastWebPageStopsTheCapture() async throws {
        let rig = Rig()
        defer { rig.remove() }
        rig.controller.addBrowserSource(url: "twitch.tv/someone")
        #expect(await rig.arm())
        let capture = try #require(rig.factory.webCaptures.first)
        let page = try #require(rig.controller.layout.videoSources.first?.id)
        rig.controller.updateLayout { $0.removeVideoSource(page) }
        #expect(await waitUntil { !capture.isRunning })
        #expect(await waitUntil { rig.controller.sourcesAreReady })
        #expect(rig.factory.running.isEmpty)
        rig.controller.setEnabled(false)
    }

    /// The page says why the sound didn't start, as it does for any source; the rest of the recording is unaffected.
    @Test func aCaptureThatCantStartIsNotedOnThePage() async throws {
        let rig = Rig()
        defer { rig.remove() }
        rig.factory.nextCaptureFailsToStart = true
        rig.controller.addBrowserSource(url: "twitch.tv/someone")
        #expect(await rig.arm())
        #expect(await waitUntil { !rig.controller.notes.isEmpty })
        #expect(rig.controller.notes == ["The web page\u{2019}s sound couldn\u{2019}t start: sTools isn\u{2019}t allowed to record app audio."])
        rig.controller.setEnabled(false)
    }

    @Test func theNotesNameSeveralPagesTogether() async throws {
        let rig = Rig()
        defer { rig.remove() }
        rig.factory.nextCaptureFailsToStart = true
        rig.controller.addBrowserSource(url: "twitch.tv/someone")
        rig.controller.addBrowserSource(url: "example.org")
        #expect(await rig.arm())
        #expect(await waitUntil { !rig.controller.notes.isEmpty })
        #expect(rig.controller.notes.first?.hasPrefix("The web pages\u{2019} sound couldn\u{2019}t start: ") == true)
        rig.controller.setEnabled(false)
    }
}
