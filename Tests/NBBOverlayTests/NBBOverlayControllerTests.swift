import CoreGraphics
import Foundation
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
        let controller = NBBOverlayController(services: makeServices(tempDirectory: tempDirectory()), connection: connection)
        #expect(controller.settings == NBBOverlaySettings.defaultValue)
        #expect(controller.isEnabled == false)
    }

    @MainActor
    @Test func changingSettingsPersistsAndReloads() async {
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory)
        let controller = NBBOverlayController(services: services, connection: NBBConnection(source: FakeEventSource([])))
        controller.settings.offsetX = 77
        controller.settings.width = 400
        await services.settings.flush()

        let reloaded = NBBOverlayController(services: makeServices(tempDirectory: directory), connection: NBBConnection(source: FakeEventSource([])))
        #expect(reloaded.settings.offsetX == 77)
        #expect(reloaded.settings.width == 400)
    }

    /// The page's preview shows only Ninjabrain Bot's live result: the intro's sample stays in the intro (spec 4,
    /// step 12).
    @MainActor
    @Test func thePreviewNeverShowsTheIntrosSample() {
        let controller = NBBOverlayController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
        controller.sample = NBBEvents.Stronghold(
            resultType: .triangulation,
            predictions: [NBBEvents.Prediction(chunkX: -41, chunkZ: 108, certainty: 0.94, overworldDistance: 1580)],
            eyeThrows: [], playerPosition: nil)
        #expect(controller.previewContent == .hidden)
        #expect(controller.previewMessages.isEmpty)
    }

    @MainActor
    @Test func setEnabledIsIdempotentAndToggles() {
        let controller = NBBOverlayController(services: makeServices(tempDirectory: tempDirectory()), connection: NBBConnection(source: FakeEventSource([])))
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
        let controller = NBBOverlayController(services: makeServices(tempDirectory: tempDirectory()), connection: connection)
        #expect(controller.isReachable == false)
        controller.setEnabled(true)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(controller.isReachable == true)
        controller.setEnabled(false)
    }
}
