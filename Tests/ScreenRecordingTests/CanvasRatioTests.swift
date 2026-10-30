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

    init(points: CGSize = CGSize(width: 1920, height: 1080), scale: CGFloat = 2) {
        self.points = points
        self.scale = scale
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
    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func audio(for source: AudioSource) -> (any AudioCapture)? { nil }
    func minecraftAudio(processID: Int32) -> (any AudioCapture)? { nil }
}

/// Counts what arming asks for and builds nothing, so arming starts no real capture.
@MainActor
private final class CountingCaptures: CaptureFactory {
    var videoRequests: [(id: UUID, canvas: PixelSize)] = []
    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? { nil }
    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)? {
        videoRequests.append((source.id, canvas))
        return nil
    }
    func audio(for source: AudioSource) -> (any AudioCapture)? { nil }
    func minecraftAudio(processID: Int32) -> (any AudioCapture)? { nil }
}

@MainActor
private func makeController(display: TestDisplay, settings: SettingsStore,
                            factory: (any CaptureFactory)? = nil) -> ScreenRecordingController {
    let services = ToolServices(
        settings: settings, displays: display.directory,
        minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])),
        permissions: PermissionCenter(prober: AlwaysGranted()))
    let factory = factory ?? NoCaptures()
    return ScreenRecordingController(services: services, makeFactory: { _ in factory }, loadAvailable: { _ in AvailableSources() })
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "stools-canvas-ratio-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `rect` as fractions of a surface `size` big.
private func fractions(_ rect: PixelRect, of size: PixelSize) -> PixelRect {
    let w = Double(size.width), h = Double(size.height)
    return PixelRect(x: rect.x / w, y: rect.y / h, width: rect.width / w, height: rect.height / h)
}

/// Where a 16:9 source's content lands in a recording `output` big, as fractions of the output.
@MainActor
private func placement(of id: UUID, in controller: ScreenRecordingController,
                       output: PixelSize = PixelSize(width: 1920, height: 1080)) -> PixelRect? {
    let content = CompositionPlan.FrameGeometry(bufferSize: PixelSize(width: 1280, height: 720))
    let plan = CompositionPlan.make(layout: controller.layout, canvas: controller.canvas, output: output, frames: [.source(id): content])
    return plan.layers.first(where: { $0.key == .source(id) }).map { fractions($0.destination, of: output) }
}

private func same(_ a: PixelRect?, _ b: PixelRect?, tolerance: Double = 1e-9) -> Bool {
    guard let a, let b else { return false }
    return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

private func same(_ a: CanvasRect, _ b: CanvasRect, tolerance: Double = 1e-9) -> Bool {
    same(PixelRect(x: a.x, y: a.y, width: a.width, height: a.height), PixelRect(x: b.x, y: b.y, width: b.width, height: b.height), tolerance: tolerance)
}

@Suite("Screen Recording keeps its layout when the display changes", .serialized) @MainActor
struct CanvasRatioTests {
    /// ducky's report: a source moved and resized when the display's resolution changed. A 4K monitor at 2x
    /// (looks like 1920 x 1080) gives a 3840 x 2160 canvas; at 1x it's 1920 x 1080.
    @Test func aSourceKeepsItsPlaceWhenTheDisplayGoesFrom2xTo1x() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = TestDisplay()
        let controller = makeController(display: display, settings: SettingsStore(directory: directory))
        #expect(controller.canvas == PixelSize(width: 3840, height: 2160))
        controller.addVideo(.camera(CameraReference(uniqueID: "cam", name: "Camera")), contentSize: PixelSize(width: 1280, height: 720))
        let id = try #require(controller.layout.videoSources.first?.id)
        let saved = controller.layout
        let before = placement(of: id, in: controller)

        display.change(scale: 1)
        #expect(controller.canvas == PixelSize(width: 1920, height: 1080))
        #expect(same(placement(of: id, in: controller), before))
        // An edit afterwards, which used to pull the layout into the new canvas, must not move it either.
        controller.updateLayout { $0.videoSources[0].opacity = 0.9 }
        #expect(same(placement(of: id, in: controller), before))

        display.change(scale: 2)
        #expect(same(placement(of: id, in: controller), before))
        #expect(controller.layout.videoSources[0].frame == saved.videoSources[0].frame)
    }

    /// Scaled modes ("More Space", "Larger Text") and another monitor change the canvas's pixel size too.
    @Test func scaledModesAndOtherResolutionsLeaveTheLayoutAlone() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = TestDisplay()
        let controller = makeController(display: display, settings: SettingsStore(directory: directory))
        controller.addVideo(.display(DisplayReference(displayID: 2, name: "Second")), contentSize: PixelSize(width: 2560, height: 1440))
        controller.addVideo(.camera(CameraReference(uniqueID: "cam", name: "Camera")), contentSize: PixelSize(width: 1920, height: 1080))
        let saved = controller.layout
        let ids = saved.videoSources.map(\.id)
        let before = ids.map { placement(of: $0, in: controller) }

        for (points, scale) in [(CGSize(width: 2560, height: 1440), 2.0), (CGSize(width: 1280, height: 720), 2.0),
                                (CGSize(width: 3840, height: 2160), 1.0), (CGSize(width: 1600, height: 900), 1.0)] {
            display.change(points: points, scale: scale)
            controller.updateLayout { $0.minecraftAudioVolume = 0.5 + Double(points.width) / 10_000 }
            #expect(controller.layout.videoSources == saved.videoSources)
            for (id, old) in zip(ids, before) { #expect(same(placement(of: id, in: controller), old)) }
        }
        // A 16:10 laptop: the frames keep their fractions; the content keeps its own shape inside them.
        display.change(points: CGSize(width: 1512, height: 945), scale: 2)
        controller.updateLayout { $0.minecraftAudioVolume = 1 }
        #expect(controller.layout.videoSources == saved.videoSources)
    }

    /// A layout made on a 1920 x 1080 canvas, in that canvas's pixels.
    private func layoutAt1080p() -> (RecordingLayout, [UUID]) {
        let canvas = PixelSize(width: 1920, height: 1080)
        let camera = VideoSource(kind: .camera(CameraReference(uniqueID: "cam", name: "Camera")),
                                 frame: PixelRect(x: 1440, y: 780, width: 440, height: 260), on: canvas,
                                 crop: CropInsets(left: 0.1, right: 0.1), cornerRadius: 24, border: SourceBorder(width: 6))
        let chat = VideoSource(kind: .window(WindowReference(windowID: 7, appName: "Chat", title: "Room")),
                               frame: PixelRect(x: 40, y: 60, width: 480, height: 720), on: canvas, opacity: 0.8)
        let page = VideoSource(kind: .browser(url: "https://example.com"),
                               frame: PixelRect(x: 960, y: 0, width: 960, height: 540), on: canvas)
        var layout = RecordingLayout()
        for source in [camera, chat, page] { layout.add(source) }
        return (layout, [camera.id, chat.id, page.id])
    }

    private let contents: [PixelSize] = [PixelSize(width: 1280, height: 720), PixelSize(width: 800, height: 1200), PixelSize(width: 1920, height: 1080)]

    @Test func aLayoutMadeAt1080pLandsTheSameAtEveryOutputSize() {
        let (layout, ids) = layoutAt1080p()
        let canvas = PixelSize(width: 1920, height: 1080)
        let frames = Dictionary(uniqueKeysWithValues: zip(ids, contents).map { (SourceKey.source($0), CompositionPlan.FrameGeometry(bufferSize: $1)) })
        let reference = CompositionPlan.make(layout: layout, canvas: canvas, output: canvas, frames: frames)
        #expect(reference.layers.count == 3)
        for output in [PixelSize(width: 3840, height: 2160), PixelSize(width: 2560, height: 1440), PixelSize(width: 1280, height: 720), PixelSize(width: 640, height: 360)] {
            let plan = CompositionPlan.make(layout: layout, canvas: canvas, output: output, frames: frames)
            for (layer, base) in zip(plan.layers, reference.layers) {
                #expect(same(fractions(layer.frame, of: output), fractions(base.frame, of: canvas)))
                #expect(same(fractions(layer.destination, of: output), fractions(base.destination, of: canvas)))
                #expect(abs(layer.cornerRadius / Double(output.height) - base.cornerRadius / 1080) < 1e-12)
                #expect(abs(layer.borderWidth / Double(output.height) - base.borderWidth / 1080) < 1e-12)
            }
        }
        // The camera: 24 px corners and a 6 px border on the 1080p canvas are 48 and 12 px at 2160p.
        let at4K = CompositionPlan.make(layout: layout, canvas: canvas, output: PixelSize(width: 3840, height: 2160), frames: frames)
        let camera = at4K.layers.first { $0.key == .source(ids[0]) }
        #expect(camera.map { abs($0.cornerRadius - 48) < 1e-9 && abs($0.borderWidth - 12) < 1e-9 } == true)
        #expect(camera?.frame.pixelAligned == PixelRect(x: 2880, y: 1560, width: 880, height: 520))
    }

    /// The canvas's pixel size (Minecraft's display at 1x, 2x or a custom size) no longer places sources.
    @Test func theCanvasPixelSizeDoesNotMoveSources() {
        let (layout, ids) = layoutAt1080p()
        let frames = Dictionary(uniqueKeysWithValues: zip(ids, contents).map { (SourceKey.source($0), CompositionPlan.FrameGeometry(bufferSize: $1)) })
        let output = PixelSize(width: 1920, height: 1080)
        let at1x = CompositionPlan.make(layout: layout, canvas: PixelSize(width: 1920, height: 1080), output: output, frames: frames)
        let at2x = CompositionPlan.make(layout: layout, canvas: PixelSize(width: 3840, height: 2160), output: output, frames: frames)
        #expect(at1x == at2x)
    }

    /// Other aspects: each frame keeps its fractions of the canvas's width and height, and each source's content
    /// keeps its own aspect ratio, fitted and centered in its frame, as before.
    @Test func otherAspectsKeepTheFractionsAndTheContentsShape() {
        let (layout, ids) = layoutAt1080p()
        let frames = Dictionary(uniqueKeysWithValues: zip(ids, contents).map { (SourceKey.source($0), CompositionPlan.FrameGeometry(bufferSize: $1)) })
        for size in [PixelSize(width: 1920, height: 1200), PixelSize(width: 2560, height: 1080), PixelSize(width: 1080, height: 1920), PixelSize(width: 1024, height: 768)] {
            let plan = CompositionPlan.make(layout: layout, canvas: size, output: size, frames: frames)
            for (layer, source) in zip(plan.layers, layout.orderedVideoSources) {
                #expect(same(fractions(layer.frame, of: size), PixelRect(x: source.frame.x, y: source.frame.y, width: source.frame.width, height: source.frame.height)))
                let content = frames[layer.key]!.bufferSize
                let visible = LayoutMath.cropRect(sourceSize: content, crop: source.crop)
                #expect(abs(layer.destination.width / layer.destination.height - visible.width / visible.height) < 1e-9)
                #expect(abs(layer.destination.midX - layer.frame.midX) < 1e-9 && abs(layer.destination.midY - layer.frame.midY) < 1e-9)
                #expect(layer.destination.width <= layer.frame.width + 1e-9 && layer.destination.height <= layer.frame.height + 1e-9)
            }
        }
    }

    /// The plate's outlines and the composite (the preview the plate shows, or the recording) put every source at
    /// the same fractions, at any plate size, output size or canvas.
    @Test func theEditorAndTheCompositorAgree() {
        let (layout, ids) = layoutAt1080p()
        let frames = Dictionary(uniqueKeysWithValues: zip(ids, contents).map { (SourceKey.source($0), CompositionPlan.FrameGeometry(bufferSize: $1)) })
        for canvas in [PixelSize(width: 1920, height: 1080), PixelSize(width: 3840, height: 2160), PixelSize(width: 2294, height: 1490)] {
            // The live preview is 640 wide (even sides), the recording the canvas or smaller.
            let preview = PixelSize(width: 640, height: Int(640 / canvas.aspectRatio)).evenSized
            for output in [preview, canvas, LayoutMath.outputSize(.p1080, canvas: canvas)] {
                let plan = CompositionPlan.make(layout: layout, canvas: canvas, output: output, frames: frames)
                for plate in [CGSize(width: 700, height: 700 / canvas.aspectRatio), CGSize(width: 413, height: 413 / canvas.aspectRatio)] {
                    let mapping = CanvasMapping(width: plate.width, height: plate.height)
                    for source in layout.videoSources {
                        let outline = RecordingCanvasEditor.outlineRect(of: source, on: mapping)
                        let layer = plan.layers.first { $0.key == .source(source.id) }
                        let drawn = layer.map { fractions($0.frame, of: output) }
                        let outlined = PixelRect(x: outline.minX / plate.width, y: outline.minY / plate.height,
                                                 width: outline.width / plate.width, height: outline.height / plate.height)
                        #expect(same(drawn, outlined))
                    }
                }
            }
        }
    }

    /// Window and display sources are captured at their display's pixel size, so an armed recorder starts its
    /// streams again when a display's resolution or backing scale changes, at the new canvas.
    @Test func anArmedRecorderRestartsItsSourcesWhenADisplayChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = TestDisplay()
        let factory = CountingCaptures()
        let controller = makeController(display: display, settings: SettingsStore(directory: directory), factory: factory)
        controller.addVideo(.window(WindowReference(windowID: 7, appName: "Chat", title: "Room")), contentSize: PixelSize(width: 1600, height: 1200))
        controller.setEnabled(true)
        #expect(await waitUntil { !factory.videoRequests.isEmpty }, "arming asked for the window source's capture")
        #expect(factory.videoRequests.map(\.canvas) == [PixelSize(width: 3840, height: 2160)])

        display.change(scale: 1)
        #expect(await waitUntil { factory.videoRequests.count >= 2 }, "the display change restarted the sources")
        #expect(factory.videoRequests.map(\.canvas) == [PixelSize(width: 3840, height: 2160), PixelSize(width: 1920, height: 1080)])
        controller.setEnabled(false)
        // Switching off runs a moment later; let it finish before the test's folder goes.
        #expect(await waitUntil { !controller.sourcesAreReady })
    }

    // MARK: Version-1 layouts

    /// A version-1 file, as sTools wrote it: frames, corner radius and border width in canvas pixels.
    private func writeVersion1Layout(to directory: URL, frame: (x: Double, y: Double, width: Double, height: Double),
                                     cornerRadius: Double, borderWidth: Double) throws {
        let json = """
        {
          "value" : {
            "audioSources" : [],
            "includesMinecraftAudio" : true,
            "minecraftAudioVolume" : 1,
            "videoSources" : [
              {
                "border" : { "colorHex" : "#D9AE52", "width" : \(borderWidth) },
                "cornerRadius" : \(cornerRadius),
                "crop" : { "bottom" : 0, "left" : 0.25, "right" : 0, "top" : 0 },
                "frame" : { "height" : \(frame.height), "width" : \(frame.width), "x" : \(frame.x), "y" : \(frame.y) },
                "id" : "6B1F1E36-0C59-4C49-9F40-6A1D3E1D2C11",
                "kind" : { "camera" : { "name" : "Camera", "uniqueID" : "cam" }, "type" : "camera" },
                "opacity" : 0.9,
                "zIndex" : 0
              }
            ]
          },
          "version" : 1
        }
        """
        try Data(json.utf8).write(to: directory.appending(path: "recordingLayout.json", directoryHint: .notDirectory))
    }

    private func savedEnvelope(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appending(path: "recordingLayout.json", directoryHint: .notDirectory))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aVersion1LayoutIsConvertedOnceWithTheCanvasItWasMadeFor() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeVersion1Layout(to: directory, frame: (1280, 720, 640, 360), cornerRadius: 27, borderWidth: 5.4)

        let display = TestDisplay(scale: 1)
        let settings = SettingsStore(directory: directory, debounce: .zero)
        let controller = makeController(display: display, settings: settings)
        let source = try #require(controller.layout.videoSources.first)
        #expect(!controller.layout.holdsLegacyPixels)
        #expect(same(source.frame, CanvasRect(x: 2.0 / 3, y: 2.0 / 3, width: 1.0 / 3, height: 1.0 / 3)))
        #expect(abs(source.cornerRadius - 0.025) < 1e-12 && abs(source.border.width - 0.005) < 1e-12)
        // Everything else comes through as it was.
        #expect(source.crop == CropInsets(left: 0.25) && source.opacity == 0.9 && source.border.colorHex == "#D9AE52")
        #expect(source.id.uuidString == "6B1F1E36-0C59-4C49-9F40-6A1D3E1D2C11")

        // Saved straight back as version 2, in fractions, without the version-1 mark.
        await settings.flush()
        let envelope = try savedEnvelope(in: directory)
        #expect(envelope["version"] as? Int == 2)
        let value = try #require(envelope["value"] as? [String: Any])
        #expect(value["legacyPixels"] == nil)

        // Read again on a 2x display (a 3840 x 2160 canvas), it isn't converted a second time.
        display.change(scale: 2)
        let again = makeController(display: display, settings: SettingsStore(directory: directory))
        #expect(again.canvas == PixelSize(width: 3840, height: 2160))
        #expect(again.layout == controller.layout)
    }

    /// A layout last edited at 2x but first read at 1x reaches past the 1x canvas: it was made on twice that.
    @Test func aVersion1LayoutMadeAt2xIsReadAt2xEvenOnA1xDisplay() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeVersion1Layout(to: directory, frame: (2517, 1397, 1280, 720), cornerRadius: 54, borderWidth: 0)
        let controller = makeController(display: TestDisplay(scale: 1), settings: SettingsStore(directory: directory))
        #expect(controller.canvas == PixelSize(width: 1920, height: 1080))
        let source = try #require(controller.layout.videoSources.first)
        #expect(same(source.frame, CanvasRect(x: 2517.0 / 3840, y: 1397.0 / 2160, width: 1.0 / 3, height: 1.0 / 3)))
        #expect(abs(source.cornerRadius - 0.025) < 1e-12)
    }

    @Test func theMigrationMarksVersion1PixelsUntilTheyAreConverted() throws {
        let raw: [String: Any] = ["videoSources": [["kind": ["type": "browser", "url": "x"], "frame": ["x": 960, "y": 540, "width": 480, "height": 270], "cornerRadius": 10.8]]]
        let migrated = try RecordingLayout.migrate(from: 1, raw)
        var layout = try JSONDecoder().decode(RecordingLayout.self, from: JSONSerialization.data(withJSONObject: migrated))
        #expect(layout.holdsLegacyPixels)
        // Not clamped into 0...1 while it still holds pixels.
        layout.sanitize()
        #expect(layout.videoSources[0].frame == CanvasRect(x: 960, y: 540, width: 480, height: 270))
        // A layout saved before converting keeps its mark.
        let resaved = try JSONDecoder().decode(RecordingLayout.self, from: JSONEncoder().encode(layout))
        #expect(resaved.holdsLegacyPixels)

        layout.convertLegacyPixels(canvas: PixelSize(width: 1920, height: 1080))
        #expect(!layout.holdsLegacyPixels)
        #expect(layout.videoSources[0].frame == CanvasRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25))
        #expect(abs(layout.videoSources[0].cornerRadius - 0.01) < 1e-12)
        // Converting is once only.
        let converted = layout
        layout.convertLegacyPixels(canvas: PixelSize(width: 3840, height: 2160))
        #expect(layout == converted)
        // Version 2 needs no migration.
        #expect(try RecordingLayout.migrate(from: 2, ["videoSources": []]).count == 1)
    }

    @Test func theCanvasAVersion1LayoutWasMadeForIsTheSmallestWholeMultipleThatHoldsIt() {
        let current = PixelSize(width: 1920, height: 1080)
        #expect(RecordingLayout.legacyCanvas(holding: [], current: current) == current)
        #expect(RecordingLayout.legacyCanvas(holding: [PixelRect(x: 1280, y: 720, width: 640, height: 360)], current: current) == current)
        #expect(RecordingLayout.legacyCanvas(holding: [PixelRect(x: 2517, y: 1397, width: 1280, height: 720)], current: current)
                == PixelSize(width: 3840, height: 2160))
        #expect(RecordingLayout.legacyCanvas(holding: [PixelRect(x: 0, y: 3000, width: 10, height: 10)], current: current)
                == PixelSize(width: 5760, height: 3240))
        #expect(RecordingLayout.legacyCanvas(holding: [PixelRect(x: .nan, y: 0, width: 10, height: 10)], current: current) == current)
    }
}
