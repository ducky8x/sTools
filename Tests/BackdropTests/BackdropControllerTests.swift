import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Backdrop
@testable import STPlatform

@MainActor
private func makeServices(tempDirectory: URL, instances: [MinecraftInstance] = []) -> ToolServices {
    let settings = SettingsStore(directory: tempDirectory)
    let displays = DisplayDirectory()
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
    // Every app switch re-orders the backdrop under Minecraft, but the full-screen fill is drawn only when it
    // changes (spec 3.1). The panels are placed without ever being ordered onto a screen.
    @MainActor
    @Test func reorderingWithoutAChangeDoesNotDrawTheFillAgain() async {
        let displays = DisplayDirectory()
        guard let display = displays.displays.first else { return }
        let window = MinecraftWindow(windowNumber: 42, processID: 4242, title: "Minecraft* 1.16.1", frame: display.frame)
        let minecraft = MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1), isFrontmost: true, displayID: display.id)
        let services = makeServices(tempDirectory: tempDirectory(), instances: [minecraft])
        services.minecraft.refresh()
        let controller = BackdropController(services: services, imagesDirectory: tempDirectory(), showsPanels: false)
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        #expect(controller.drawCount == 1)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        controller.reconcile()
        #expect(controller.drawCount == 1)

        controller.settings.fill.color = "#223344"
        #expect(controller.drawCount == 2)
        controller.settings.opacityPercent = 50
        #expect(controller.drawCount == 3)
    }

    // A hidden panel keeps its full-screen layer, and a decoded image is tens of megabytes: switching off lets
    // both go, and switching on builds them again.
    @MainActor
    @Test func switchingOffReleasesThePanelsAndTheirImages() {
        let displays = DisplayDirectory()
        guard let display = displays.displays.first else { return }
        let window = MinecraftWindow(windowNumber: 42, processID: 4242, title: "Minecraft* 1.16.1", frame: display.frame)
        let minecraft = MinecraftInstance(window: window, launchDate: Date(timeIntervalSince1970: 1), isFrontmost: true, displayID: display.id)
        let directory = tempDirectory()
        let services = makeServices(tempDirectory: directory, instances: [minecraft])
        services.minecraft.refresh()
        let controller = BackdropController(services: services, imagesDirectory: directory.appending(path: "Images"), showsPanels: false)
        let source = directory.appending(path: "source.png")
        writeOnePixelPNG(to: source)
        controller.importImage(from: source)
        #expect(controller.settings.fill.kind == .image)

        controller.setEnabled(true)
        #expect(controller.panelCount == 1)
        #expect(controller.loadedImageCount == 1)

        controller.setEnabled(false)
        #expect(controller.panelCount == 0)
        #expect(controller.loadedImageCount == 0)

        controller.setEnabled(true)
        #expect(controller.panelCount == 1)
        #expect(controller.image(for: controller.settings.fill) != nil)
        controller.setEnabled(false)
    }

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
