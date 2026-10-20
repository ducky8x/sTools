import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Crosshair
@testable import STPlatform

@MainActor
private func makeServices(tempDirectory: URL, instances: [MinecraftInstance] = []) -> ToolServices {
    makeServices(tempDirectory: tempDirectory, source: StaticMinecraftWindowSource(instances: instances))
}

@MainActor
private func makeServices(tempDirectory: URL, source: StaticMinecraftWindowSource) -> ToolServices {
    let settings = SettingsStore(directory: tempDirectory)
    let displays = DisplayDirectory()
    let minecraft = MinecraftLocator(source: source)
    let permissions = PermissionCenter(prober: NeverPromptingProber())
    return ToolServices(settings: settings, displays: displays, minecraft: minecraft, permissions: permissions)
}

private struct NeverPromptingProber: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

@MainActor
private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-crosshair-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Crosshair controller", .serialized)
struct CrosshairControllerTests {
    @MainActor
    @Test func loadsDefaultsWhenNothingIsStored() {
        let services = makeServices(tempDirectory: tempDirectory())
        let controller = CrosshairController(services: services)
        #expect(controller.settings == CrosshairSettings())
        #expect(controller.isEnabled == false)
    }

    @MainActor
    @Test func changingSettingsPersistsAndReloads() async {
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory)
        let controller = CrosshairController(services: services)
        controller.settings.fillHex = "#112233"
        controller.settings.size = 42
        await services.settings.flush()

        let reloaded = CrosshairController(services: makeServices(tempDirectory: directory))
        #expect(reloaded.settings.fillHex == "#112233")
        #expect(reloaded.settings.size == 42)
    }

    @MainActor
    @Test func setEnabledIsIdempotentAndToggles() {
        let controller = CrosshairController(services: makeServices(tempDirectory: tempDirectory()))
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

    // Regression: "Show only while Minecraft is focused" decided once, when the tool was switched on, and
    // never looked again when Minecraft gained or lost focus. Minecraft stays unfocused here, so the test
    // never puts a crosshair on screen.
    @MainActor
    @Test func focusOnlyModeLooksAgainWhenMinecraftChanges() async throws {
        func minecraft(x: CGFloat) -> MinecraftInstance {
            let window = MinecraftWindow(windowNumber: 42, processID: 4242, title: "Minecraft* 1.16.1", frame: CGRect(x: x, y: 0, width: 800, height: 600))
            return MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1), isFrontmost: false)
        }
        let source = StaticMinecraftWindowSource(instances: [minecraft(x: 0)])
        let services = makeServices(tempDirectory: tempDirectory(), source: source)
        services.minecraft.start()
        defer { services.minecraft.stop() }
        let controller = CrosshairController(services: services)
        controller.settings.visibleOnlyWhileMinecraftFocused = true
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        #expect(!controller.isOverlayShown)

        let looks = controller.placementCount
        source.instances = [minecraft(x: 40)]
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.placementCount == looks, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.placementCount > looks, "the crosshair should look again when Minecraft changes")
        #expect(!controller.isOverlayShown)
    }

    @MainActor
    @Test func importingAnUnreadableFileReportsAnErrorAndKeepsTheShape() {
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory)
        let controller = CrosshairController(services: services)
        let bogus = directory.appending(path: "not-an-image.txt")
        try? "hello".write(to: bogus, atomically: true, encoding: .utf8)

        controller.importImage(from: bogus)

        #expect(controller.imageImportError != nil)
        #expect(controller.settings.shape != .image)
    }

    @MainActor
    @Test func importingARealImageSwitchesToImageShapeAndClearsTheError() {
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory)
        let controller = CrosshairController(services: services, imagesDirectory: directory.appending(path: "Images"))
        let source = directory.appending(path: "source.png")
        writeOnePixelPNG(to: source)

        controller.importImage(from: source)

        #expect(controller.imageImportError == nil)
        #expect(controller.settings.shape == .image)
        #expect(controller.settings.imageName != nil)
        #expect(controller.previewImage != nil)
    }
}

@MainActor
private func writeOnePixelPNG(to url: URL) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
