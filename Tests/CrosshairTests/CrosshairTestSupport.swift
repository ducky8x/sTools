import CoreGraphics
import Foundation
@testable import Crosshair
@testable import STPlatform

/// A display that exists only in tests. Nothing is ever drawn on it, so it may overlap the real screens.
func syntheticDisplay(id: UInt32 = 1, frame: CGRect, scale: CGFloat, isMain: Bool = true) -> DisplayInfo {
    DisplayInfo(
        id: id, name: "Display \(id)", frame: frame, bounds: frame, backingScale: scale,
        pixelSize: CGSize(width: frame.width * scale, height: frame.height * scale), isMain: isMain)
}

/// One plain 1920 x 1080 display, so no test depends on the real screens.
let fullHDDisplay = syntheticDisplay(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)

@MainActor
func makeServices(tempDirectory: URL, instances: [MinecraftInstance] = [], displays: [DisplayInfo] = [fullHDDisplay]) -> ToolServices {
    makeServices(tempDirectory: tempDirectory, source: StaticMinecraftWindowSource(instances: instances), displays: displays)
}

@MainActor
func makeServices(tempDirectory: URL, source: StaticMinecraftWindowSource, displays: [DisplayInfo] = [fullHDDisplay]) -> ToolServices {
    let settings = SettingsStore(directory: tempDirectory)
    let displays = DisplayDirectory(screenProvider: { displays })
    let minecraft = MinecraftLocator(source: source)
    let permissions = PermissionCenter(prober: NeverPromptingProber())
    return ToolServices(settings: settings, displays: displays, minecraft: minecraft, permissions: permissions)
}

/// A controller whose panel is never ordered onto a screen, with its images in the test's temp directory.
@MainActor
func makeController(_ services: ToolServices) -> CrosshairController {
    CrosshairController(services: services, imagesDirectory: services.settings.directory.appending(path: "Images"), showsPanel: false)
}

struct NeverPromptingProber: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

@MainActor
func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-crosshair-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
