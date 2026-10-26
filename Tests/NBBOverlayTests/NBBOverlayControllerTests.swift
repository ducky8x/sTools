import CoreGraphics
import Foundation
import STDesign
import Synchronization
import Testing
@testable import NBBOverlay
@testable import STPlatform

/// The tests' one display, its main, far outside every real display, so the overlay panel ordered in never shows on
/// screen.
private let offScreenDisplay = DisplayInfo(
    id: 1, name: "Off screen", frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080),
    bounds: CGRect(x: -9000, y: 9000, width: 1920, height: 1080), backingScale: 1,
    pixelSize: CGSize(width: 1920, height: 1080), isMain: true)

@MainActor
private func makeServices(tempDirectory: URL, instances: [MinecraftInstance] = []) -> ToolServices {
    let settings = SettingsStore(directory: tempDirectory)
    let displays = DisplayDirectory(screenProvider: { [offScreenDisplay] })
    let minecraft = MinecraftLocator(source: StaticMinecraftWindowSource(instances: instances))
    let permissions = PermissionCenter(prober: NeverPromptingProber())
    return ToolServices(settings: settings, displays: displays, minecraft: minecraft, permissions: permissions)
}

private struct NeverPromptingProber: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// A controller that never scans for the person's real Ninjabrain Bots or reads their windows.
@MainActor
private func inertNBBController(
    services: ToolServices, connection: NBBConnection = NBBConnection(source: FakeEventSource([])), theme: STTheme? = nil
) -> NBBOverlayController {
    NBBOverlayController(services: services, connection: connection, copies: NBBCopiesMonitor(scanner: NoNBBCopiesScanner()), theme: theme)
}

@MainActor
private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-nbb-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("NBB overlay controller", .serialized)
struct NBBOverlayControllerTests {
    @MainActor
    @Test func loadsDefaultsWhenNothingIsStored() {
        let connection = NBBConnection(source: FakeEventSource([]))
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: connection)
        #expect(controller.settings == NBBOverlaySettings.defaultValue)
        #expect(controller.isEnabled == false)
    }

    @MainActor
    @Test func changingSettingsPersistsAndReloads() async {
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory)
        let controller = inertNBBController(services: services, connection: NBBConnection(source: FakeEventSource([])))
        controller.settings.offsetX = 77
        controller.settings.width = 400
        await services.settings.flush()

        let reloaded = inertNBBController(services: makeServices(tempDirectory: directory), connection: NBBConnection(source: FakeEventSource([])))
        #expect(reloaded.settings.offsetX == 77)
        #expect(reloaded.settings.width == 400)
    }

    /// Moving the overlay, or a refresh that changes nothing it draws, leaves its content alone; new content, a new
    /// look or switching off and on again builds it again.
    @MainActor
    @Test func onlyAChangeInWhatItDrawsRebuildsTheOverlay() {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        controller.sample = NBBEvents.Stronghold(
            resultType: .triangulation,
            predictions: [NBBEvents.Prediction(chunkX: -41, chunkZ: 108, certainty: 0.94, overworldDistance: 1580)],
            eyeThrows: [], playerPosition: nil)
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        #expect(controller.drawCount == 1)

        controller.settings.offsetX += 40
        controller.settings.offsetY -= 25
        #expect(controller.drawCount == 1, "moving only moves the panel")

        controller.settings.width = 400
        #expect(controller.drawCount == 2)

        controller.setEnabled(false)
        controller.setEnabled(true)
        #expect(controller.drawCount == 3, "switching off let the content go")
    }

    static let result = NBBEvents.Stronghold(
        resultType: .triangulation,
        predictions: [NBBEvents.Prediction(chunkX: -41, chunkZ: 108, certainty: 0.94, overworldDistance: 1580)],
        eyeThrows: [], playerPosition: nil)

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 2) async {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Spec 5.1.1: when Ninjabrain Bot resets, the overlay fades out; new data fades it back in.
    @MainActor @Test func aResetFadesTheOverlayOutThenHidesIt() async {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        controller.settings.fadeSeconds = 0.15
        controller.sample = Self.result
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        #expect(controller.isOverlayVisible)
        controller.sample = nil
        #expect(controller.isOverlayVisible, "still fading out")
        await waitUntil { !controller.isOverlayVisible }
        #expect(!controller.isOverlayVisible)
    }

    @MainActor @Test func newDataDuringTheFadeBringsTheOverlayStraightBack() async throws {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        controller.settings.fadeSeconds = 0.2
        controller.sample = Self.result
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        controller.sample = nil
        controller.sample = Self.result
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isOverlayVisible, "the fade-out's end didn't hide it")
    }

    /// The first result after a reset is the one a runner waits for: it shows at once at full opacity, not over a
    /// fade-in, and also when it comes partway through the fade-out. The reset itself still fades out.
    @MainActor @Test func aResultAfterAResetShowsAtOnce() async {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        controller.settings.fadeSeconds = 0.5
        controller.sample = Self.result
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        #expect(controller.isOverlayVisible && controller.panel.alphaValue == 1)

        controller.sample = nil
        #expect(controller.isOverlayVisible, "the reset fades out")
        controller.sample = Self.result
        #expect(controller.isOverlayVisible && controller.panel.alphaValue == 1, "back at once partway through the fade-out")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.panel.alphaValue == 1, "the fade-out's animation stopped")

        controller.sample = nil
        await waitUntil({ !controller.isOverlayVisible }, seconds: 5)
        #expect(!controller.isOverlayVisible)
        controller.sample = Self.result
        #expect(controller.isOverlayVisible && controller.panel.alphaValue == 1, "shown at once after the fade-out ended")
    }

    /// Each result goes into the hosting view already in the panel instead of a new one.
    @MainActor @Test func aNewResultKeepsTheHostingView() {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        controller.sample = Self.result
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        let host = controller.panel.contentView.map(ObjectIdentifier.init)
        var next = Self.result
        next.predictions[0].certainty = 0.5
        controller.sample = next
        #expect(controller.drawCount == 2)
        #expect(controller.panel.contentView.map(ObjectIdentifier.init) == host)
    }

    /// A result Ninjabrain Bot pushes is drawn in the main-actor turn it arrives in: from the server's write to the drawn
    /// panel, the fastest of several results (the fastest, so a busy machine can't make it flaky) takes a few
    /// milliseconds, where it took about 16 ms before (a byte at a time, then a hop and a new hosting view).
    @MainActor @Test func aPushedResultIsDrawnAtOnce() async throws {
        let server = try LocalSSEServer(values: freshNinjabrainBot)
        defer { server.stop() }
        let connection = NBBConnection(baseURL: server.baseURL, source: URLSessionEventSource())
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: connection)
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        await waitUntil({ connection.stronghold != nil && server.subscribers("/api/v1/boat/events") == 1 }, seconds: 10)
        var fastest = Duration.seconds(10)
        for seed in 0..<20 where fastest >= .milliseconds(10) {
            let sentAt = Mutex<ContinuousClock.Instant?>(nil)
            var drawnAt: ContinuousClock.Instant?
            controller.didDraw = { drawnAt = .now }
            let result = strongholdResult(seed)
            Task.detached {
                sentAt.withLock { $0 = .now }
                server.send("/api/v1/stronghold/events", result)
            }
            await waitUntil({ drawnAt != nil }, seconds: 5)
            if let drawnAt, let sent = sentAt.withLock({ $0 }) { fastest = min(fastest, drawnAt - sent) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fastest < .milliseconds(10), "fastest result took \(fastest) from Ninjabrain Bot to the panel")
    }

    @MainActor @Test func withFadingOffOrMotionReducedAResetHidesAtOnce() {
        let reduced = STTheme()
        reduced.motionMode = .reduced
        for (fadeOn, theme) in [(false, STTheme?.none), (true, reduced)] {
            let controller = inertNBBController(
                services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])), theme: theme)
            controller.settings.fadeOnResetEnabled = fadeOn
            controller.sample = Self.result
            controller.setEnabled(true)
            #expect(controller.fadeDuration == 0)
            controller.sample = nil
            #expect(!controller.isOverlayVisible)
            controller.setEnabled(false)
        }
    }

    /// ducky's case: an old copy holds the API with nothing in it, and the newer copy in use has a result. The overlay
    /// follows the newer copy, read from its window; picking the old one switches back to the API.
    @MainActor @Test func theOverlayFollowsTheChosenCopyReadFromItsWindow() async {
        /// Records each read and whether it ran on the main thread.
        final class FakeWindow: NBBWindowReading, @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [(pid: Int32, onMainThread: Bool)] = []
            var reads: [Int32] { lock.withLock { recorded.map(\.pid) } }
            var readsOnMainThread: Int { lock.withLock { recorded.filter(\.onMainThread).count } }
            func read(pid: Int32) async -> NBBWindowSnapshot? {
                lock.withLock { recorded.append((pid, pthread_main_np() != 0)) }
                return NBBWindowSnapshot(stronghold: NBBOverlayControllerTests.result, messages: ["A note from the window."])
            }
        }
        let scanner = FakeCopiesScanner([
            NBBCopy(pid: 873, startedAt: Date(timeIntervalSince1970: 10), arguments: [], holdsAPI: true),
            NBBCopy(pid: 92616, startedAt: Date(timeIntervalSince1970: 20), arguments: [], holdsAPI: false),
        ])
        let monitor = NBBCopiesMonitor(scanner: scanner, control: FakeCopiesControl(scanner: scanner))
        let window = FakeWindow()
        let controller = NBBOverlayController(
            services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])),
            copies: monitor, windowReader: window, windowPollInterval: .milliseconds(20))
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        await waitUntil { controller.readsWindow && controller.windowSnapshot != nil }
        #expect(controller.readsWindow)
        #expect(window.reads.first == 92616)
        #expect(controller.stronghold == Self.result)
        #expect(controller.isReachable)
        #expect(controller.previewMessages.map(\.text) == ["A note from the window."])
        #expect(controller.isOverlayVisible)
        await waitUntil { window.reads.count >= 3 }
        #expect(window.reads.count >= 3 && window.readsOnMainThread == 0, "the window is read off the main actor")

        monitor.choice = .copy(873)
        await waitUntil { controller.windowSnapshot == nil }
        #expect(!controller.readsWindow)
        #expect(controller.stronghold == nil, "the API copy has nothing yet")
        let readsBefore = window.reads.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(window.reads.count == readsBefore, "the window isn't read while the API copy is followed")
    }

    /// A copy read from its window is looked at ten times a second, so a change shows within a tenth of a second (it
    /// was half a second); most looks ask only a few texts (`AXNBBWindowReader`).
    @MainActor @Test func aWindowIsLookedAtTenTimesASecond() {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()))
        #expect(controller.windowPollInterval == .milliseconds(100))
        #expect(AXNBBWindowReader.fullReadInterval == .seconds(1))
    }

    /// The copies are looked for only while the tool is on.
    @MainActor @Test func theCopiesAreScannedOnlyWhileTheToolIsOn() async throws {
        let scanner = FakeCopiesScanner([NBBCopy(pid: 873, startedAt: Date(timeIntervalSince1970: 10), arguments: [], holdsAPI: true)])
        let monitor = NBBCopiesMonitor(
            scanner: scanner, control: FakeCopiesControl(scanner: scanner), interval: .milliseconds(10), idleInterval: .milliseconds(10))
        let controller = NBBOverlayController(
            services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])), copies: monitor)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scanner.scanCount == 0)
        controller.setEnabled(true)
        await waitUntil { monitor.copies.count == 1 }
        #expect(monitor.copies.count == 1 && scanner.scanCountOnMainThread == 0)
        controller.setEnabled(false)
        #expect(monitor.copies.isEmpty && !monitor.isWatching)
        try await Task.sleep(for: .milliseconds(30))
        let scans = scanner.scanCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(scanner.scanCount == scans)
    }

    /// The page's preview shows only Ninjabrain Bot's live result: the intro's sample stays in the intro (spec 4,
    /// step 12).
    @MainActor
    @Test func thePreviewNeverShowsTheIntrosSample() {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        controller.sample = NBBEvents.Stronghold(
            resultType: .triangulation,
            predictions: [NBBEvents.Prediction(chunkX: -41, chunkZ: 108, certainty: 0.94, overworldDistance: 1580)],
            eyeThrows: [], playerPosition: nil)
        #expect(controller.previewContent == .hidden)
        #expect(controller.previewMessages.isEmpty)
    }

    @MainActor
    @Test func setEnabledIsIdempotentAndToggles() {
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        #expect(controller.isEnabled == false)
        controller.setEnabled(true)
        #expect(controller.isEnabled == true)
        controller.setEnabled(true)
        #expect(controller.isEnabled == true)
        controller.setEnabled(false)
        #expect(controller.isEnabled == false)
        controller.setEnabled(false)
        #expect(controller.isEnabled == false)
    }

    @MainActor
    @Test func startsNotReachableAndBecomesReachableOnConnect() async {
        // All six subscriptions plus the version check share this one fake; it must keep succeeding
        // for every one of them, not just whichever happens to connect first.
        let connection = NBBConnection(source: FakeEventSource([.event(#"{"resultType":"NONE"}"#)], repeatsLastOutcome: true))
        let controller = inertNBBController(services: makeServices(tempDirectory: tempDirectory()), connection: connection)
        #expect(controller.isReachable == false)
        controller.setEnabled(true)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(controller.isReachable == true)
        controller.setEnabled(false)
    }
}
