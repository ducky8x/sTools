import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Backdrop
@testable import STPlatform

/// The tests' one display, its main, far outside every real display, so a backdrop panel ordered in never shows on
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
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-backdrop-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Backdrop controller", .serialized)
struct BackdropControllerTests {
    @MainActor
    @Test func loadsDefaultsWhenNothingIsStored() {
        let controller = BackdropController(services: makeServices(tempDirectory: tempDirectory()))
        #expect(controller.settings == BackdropSettings.defaultValue)
        #expect(controller.isEnabled == false)
    }

    @MainActor
    @Test func changingSettingsPersistsAndReloads() async {
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory)
        let controller = BackdropController(services: services)
        controller.settings.fill.color = "#112233"
        controller.settings.opacityPercent = 42
        await services.settings.flush()

        let reloaded = BackdropController(services: makeServices(tempDirectory: directory))
        #expect(reloaded.settings.fill.color == "#112233")
        #expect(reloaded.settings.opacityPercent == 42)
    }

    @MainActor
    @Test func setEnabledIsIdempotentAndToggles() {
        let controller = BackdropController(services: makeServices(tempDirectory: tempDirectory()))
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
    @Test func coveringAndUncoveringADisplayUpdatesSettings() {
        let controller = BackdropController(services: makeServices(tempDirectory: tempDirectory()))
        #expect(controller.isCovered(displayID: 7) == false)
        controller.setCovered(true, displayID: 7)
        #expect(controller.isCovered(displayID: 7))
        #expect(controller.settings.additionalDisplayIDs == [7])
        // Idempotent: covering an already-covered display doesn't duplicate it.
        controller.setCovered(true, displayID: 7)
        #expect(controller.settings.additionalDisplayIDs == [7])
        controller.setCovered(false, displayID: 7)
        #expect(controller.isCovered(displayID: 7) == false)
        #expect(controller.settings.additionalDisplayIDs.isEmpty)
    }

    @MainActor
    @Test func uncoveringADisplayDropsItsFillOverride() {
        let controller = BackdropController(services: makeServices(tempDirectory: tempDirectory()))
        controller.setCovered(true, displayID: 3)
        var fill = BackdropSettings.Fill()
        fill.color = "#ABCDEF"
        controller.setDisplayFill(fill, for: 3)
        #expect(controller.settings.displayFills.count == 1)
        controller.setCovered(false, displayID: 3)
        #expect(controller.settings.displayFills.isEmpty)
    }

    @MainActor
    @Test func settingADisplayFillReplacesRatherThanDuplicates() {
        let controller = BackdropController(services: makeServices(tempDirectory: tempDirectory()))
        var first = BackdropSettings.Fill()
        first.color = "#111111"
        controller.setDisplayFill(first, for: 1)
        var second = BackdropSettings.Fill()
        second.color = "#222222"
        controller.setDisplayFill(second, for: 1)
        #expect(controller.settings.displayFills.count == 1)
        #expect(controller.settings.fill(for: 1).color == "#222222")
    }

    @MainActor
    @Test func importingAnUnreadableFileReportsAnErrorAndKeepsTheShape() {
        let directory = tempDirectory()
        let controller = BackdropController(services: makeServices(tempDirectory: directory))
        let bogus = directory.appending(path: "not-an-image.txt")
        try? "hello".write(to: bogus, atomically: true, encoding: .utf8)

        controller.importImage(from: bogus)

        #expect(controller.imageImportError != nil)
        #expect(controller.settings.fill.kind != .image)
    }

    @MainActor
    @Test func importingARealImageSwitchesToImageFillAndClearsTheError() {
        let directory = tempDirectory()
        let controller = BackdropController(services: makeServices(tempDirectory: directory), imagesDirectory: directory.appending(path: "Images"))
        let source = directory.appending(path: "source.png")
        writeOnePixelPNG(to: source)

        controller.importImage(from: source)

        #expect(controller.imageImportError == nil)
        #expect(controller.settings.fill.kind == .image)
        #expect(controller.settings.fill.imageName != nil)
        #expect(controller.image(for: controller.settings.fill) != nil)
    }

    @MainActor
    @Test func importingAnImageForADisplayOverrideDoesNotTouchTheMainFill() {
        let directory = tempDirectory()
        let controller = BackdropController(services: makeServices(tempDirectory: directory), imagesDirectory: directory.appending(path: "Images"))
        let source = directory.appending(path: "source.png")
        writeOnePixelPNG(to: source)
        controller.setCovered(true, displayID: 9)

        controller.importImage(from: source, forDisplayID: 9)

        #expect(controller.imageImportError(for: 9) == nil)
        #expect(controller.settings.fill(for: 9).kind == .image)
        #expect(controller.settings.fill.kind == .color, "the main (Minecraft display) fill is untouched")
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
