import CoreGraphics
import Foundation
import Testing
@testable import ScreenRecording
@testable import STPlatform

/// One synthetic display, off any real screen, whose resolution and backing scale a test can change the way
/// macOS does (a 4K monitor switched between 2x and 1x, a scaled mode). Nothing is ever shown on it.
@MainActor
private final class TestDisplay {
    var points = CGSize(width: 1920, height: 1080)
    var scale: CGFloat = 2
    private(set) var directory: DisplayDirectory!

    init() {
        directory = DisplayDirectory(screenProvider: { [unowned self] in [self.info] })
    }

    var info: DisplayInfo {
        let frame = CGRect(origin: CGPoint(x: -9000, y: -9000), size: points)
        return DisplayInfo(id: 9000, name: "Test display", frame: frame, bounds: frame, backingScale: scale,
                           pixelSize: CGSize(width: points.width * scale, height: points.height * scale), isMain: true)
    }

    func change(points: CGSize? = nil, scale: CGFloat? = nil) {
        if let points { self.points = points }
        if let scale { self.scale = scale }
        directory.refresh()
    }
}

private struct AlwaysGranted: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// Builds nothing: these tests never arm the recorder, so nothing is captured.
@MainActor
private struct NoCaptures: CaptureFactory {
    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func video(for source: VideoSource, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func audio(for source: AudioSource) -> (any AudioCapture)? { nil }
    func minecraftAudio(processID: Int32) -> (any AudioCapture)? { nil }
}

@MainActor
private func makeController(display: TestDisplay, settings: URL) -> ScreenRecordingController {
    let services = ToolServices(
        settings: SettingsStore(directory: settings), displays: display.directory,
        minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])),
        permissions: PermissionCenter(prober: AlwaysGranted()))
    return ScreenRecordingController(services: services, makeFactory: { _ in NoCaptures() }, loadAvailable: { _ in AvailableSources() })
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "stools-canvas-ratio-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Where a 16:9 source's content lands in a recording `output` big, as fractions of the output.
@MainActor
private func placement(of id: UUID, in controller: ScreenRecordingController,
                       output: PixelSize = PixelSize(width: 1920, height: 1080)) -> PixelRect? {
    let content = CompositionPlan.FrameGeometry(bufferSize: PixelSize(width: 1280, height: 720))
    let plan = CompositionPlan.make(layout: controller.layout, canvas: controller.canvas, output: output, frames: [.source(id): content])
    guard let rect = plan.layers.first(where: { $0.key == .source(id) })?.destination else { return nil }
    let w = Double(output.width), h = Double(output.height)
    return PixelRect(x: rect.x / w, y: rect.y / h, width: rect.width / w, height: rect.height / h)
}

private func same(_ a: PixelRect?, _ b: PixelRect?, tolerance: Double = 1e-6) -> Bool {
    guard let a, let b else { return false }
    return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

@Suite("Screen Recording keeps its layout when the display changes", .serialized) @MainActor
struct CanvasRatioTests {
    /// ducky's report: a source moved and resized when the display's resolution changed. A 4K monitor at 2x
    /// (looks like 1920 x 1080) gives a 3840 x 2160 canvas; at 1x it's 1920 x 1080.
    @Test func aSourceKeepsItsPlaceWhenTheDisplayGoesFrom2xTo1x() throws {
        let settings = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: settings) }
        let display = TestDisplay()
        let controller = makeController(display: display, settings: settings)
        #expect(controller.canvas == PixelSize(width: 3840, height: 2160))
        controller.addVideo(.camera(CameraReference(uniqueID: "cam", name: "Camera")), contentSize: PixelSize(width: 1280, height: 720))
        let id = try #require(controller.layout.videoSources.first?.id)
        let before = placement(of: id, in: controller)

        display.change(scale: 1)
        #expect(controller.canvas == PixelSize(width: 1920, height: 1080))
        withKnownIssue("Frames are stored in canvas pixels, so they move when the canvas's pixel size changes") {
            #expect(same(placement(of: id, in: controller), before))
            // An edit afterwards, which pulls the layout into the new canvas, must not move it either.
            controller.updateLayout { $0.videoSources[0].opacity = 0.9 }
            #expect(same(placement(of: id, in: controller), before))

            display.change(scale: 2)
            #expect(same(placement(of: id, in: controller), before))
        }
    }
}
