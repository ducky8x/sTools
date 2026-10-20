import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ScreenRecording

/// A BGRA buffer filled by `color(x, y)` (top-left origin), as (r, g, b).
private func makeBuffer(_ width: Int, _ height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = color(x, y)
            let p = base + y * stride + x * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

private func solid(_ width: Int, _ height: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> CVPixelBuffer {
    makeBuffer(width, height) { _, _ in (r, g, b) }
}

/// (r, g, b) at (x, y), top-left origin.
private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return (Int(p[2]), Int(p[1]), Int(p[0]))
}

private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 4) -> Bool {
    abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
}

private func frame(_ buffer: CVPixelBuffer, content: PixelRect? = nil) -> VideoFrame {
    VideoFrame(pixelBuffer: buffer, contentRect: content, hostTime: .zero)
}

@Suite struct CompositionPlanTests {
    let canvas = PixelSize(width: 1920, height: 1080)

    @Test func theBaseFillsACanvasOfItsOwnSize() {
        let plan = CompositionPlan.make(layout: RecordingLayout(), canvas: canvas, output: canvas,
                                        frames: [.base: .init(bufferSize: canvas)])
        #expect(plan.layers.map(\.destination) == [PixelRect(x: 0, y: 0, width: 1920, height: 1080)])
    }

    @Test func aLargerCustomCanvasCentersTheBase() {
        let plan = CompositionPlan.make(layout: RecordingLayout(), canvas: PixelSize(width: 2000, height: 1080), output: PixelSize(width: 2000, height: 1080),
                                        frames: [.base: .init(bufferSize: canvas)])
        #expect(plan.layers[0].destination == PixelRect(x: 40, y: 0, width: 1920, height: 1080))
    }

    @Test func sourcesAreCroppedFittedAndScaledToTheOutput() {
        var layout = RecordingLayout()
        let id = UUID()
        layout.add(VideoSource(id: id, kind: .browser(url: "x"), frame: PixelRect(x: 960, y: 540, width: 480, height: 540),
                               crop: CropInsets(left: 0.5), cornerRadius: 20, border: SourceBorder(width: 4)))
        let plan = CompositionPlan.make(layout: layout, canvas: canvas, output: PixelSize(width: 960, height: 540),
                                        frames: [.source(id): .init(bufferSize: PixelSize(width: 800, height: 900), contentRect: PixelRect(x: 0, y: 0, width: 800, height: 600))])
        let layer = plan.layers[0]
        #expect(layer.sourceRect == PixelRect(x: 400, y: 0, width: 400, height: 600))
        // 400×600 fitted into 480×540 is 360×540, centered; then halved for the output.
        #expect(layer.destination == PixelRect(x: 510, y: 270, width: 180, height: 270))
        #expect(layer.cornerRadius == 10 && layer.borderWidth == 2)
    }

    @Test func missingAndInvisibleSourcesAreLeftOut() {
        var layout = RecordingLayout()
        let shown = VideoSource(kind: .browser(url: "a"), frame: PixelRect(x: 0, y: 0, width: 100, height: 100))
        var hidden = VideoSource(kind: .browser(url: "b"), frame: PixelRect(x: 0, y: 0, width: 100, height: 100))
        hidden.opacity = 0
        let absent = VideoSource(kind: .browser(url: "c"), frame: PixelRect(x: 0, y: 0, width: 100, height: 100))
        layout.add(shown); layout.add(hidden); layout.add(absent)
        let size = CompositionPlan.FrameGeometry(bufferSize: PixelSize(width: 10, height: 10))
        let plan = CompositionPlan.make(layout: layout, canvas: canvas, output: canvas,
                                        frames: [.source(shown.id): size, .source(hidden.id): size])
        #expect(plan.layers.map(\.key) == [.source(shown.id)])
    }
}

@Suite(.serialized) struct CompositorRenderTests {
    @Test func aSourceIsDrawnOverTheBaseWhereThePlanSays() throws {
        let compositor = try Compositor(outputSize: PixelSize(width: 200, height: 100))
        var layout = RecordingLayout()
        let id = UUID()
        layout.add(VideoSource(id: id, kind: .browser(url: "x"), frame: PixelRect(x: 100, y: 50, width: 100, height: 50)))
        let frames = [SourceKey.base: frame(solid(200, 100, 255, 0, 0)), .source(id): frame(solid(40, 20, 0, 255, 0))]
        let plan = CompositionPlan.make(layout: layout, canvas: PixelSize(width: 200, height: 100), output: compositor.outputSize,
                                        frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        let output = try #require(compositor.render(plan, frames: frames))
        #expect(near(pixel(output, 10, 10), (255, 0, 0)))
        #expect(near(pixel(output, 150, 75), (0, 255, 0)))
        #expect(near(pixel(output, 150, 40), (255, 0, 0)))
        #expect(near(pixel(output, 90, 75), (255, 0, 0)))
    }

    @Test func croppingShowsOnlyTheKeptPart() throws {
        let compositor = try Compositor(outputSize: PixelSize(width: 100, height: 100))
        var layout = RecordingLayout()
        let id = UUID()
        layout.add(VideoSource(id: id, kind: .browser(url: "x"), frame: PixelRect(x: 0, y: 0, width: 100, height: 100), crop: CropInsets(left: 0.5)))
        // Left half blue, right half yellow.
        let split = makeBuffer(100, 50) { x, _ in x < 50 ? (0, 0, 255) : (255, 255, 0) }
        let frames = [SourceKey.source(id): frame(split)]
        let plan = CompositionPlan.make(layout: layout, canvas: PixelSize(width: 100, height: 100), output: compositor.outputSize,
                                        frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        let output = try #require(compositor.render(plan, frames: frames))
        #expect(near(pixel(output, 5, 50), (255, 255, 0)))
        #expect(near(pixel(output, 95, 50), (255, 255, 0)))
    }

    @Test func opacityBlendsWithWhatIsBelow() throws {
        let compositor = try Compositor(outputSize: PixelSize(width: 100, height: 100))
        var layout = RecordingLayout()
        let id = UUID()
        layout.add(VideoSource(id: id, kind: .browser(url: "x"), frame: PixelRect(x: 0, y: 0, width: 100, height: 100), opacity: 0.5))
        let frames = [SourceKey.base: frame(solid(100, 100, 255, 0, 0)), .source(id): frame(solid(100, 100, 0, 255, 0))]
        let plan = CompositionPlan.make(layout: layout, canvas: PixelSize(width: 100, height: 100), output: compositor.outputSize,
                                        frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        let output = try #require(compositor.render(plan, frames: frames))
        #expect(near(pixel(output, 50, 50), (128, 128, 0), tolerance: 8))
    }

    @Test func roundedCornersAndBordersAreDrawn() throws {
        let compositor = try Compositor(outputSize: PixelSize(width: 100, height: 100))
        var layout = RecordingLayout()
        let id = UUID()
        layout.add(VideoSource(id: id, kind: .browser(url: "x"), frame: PixelRect(x: 0, y: 0, width: 100, height: 100),
                               cornerRadius: 30, border: SourceBorder(width: 6, colorHex: "#0000FF")))
        let frames = [SourceKey.base: frame(solid(100, 100, 255, 0, 0)), .source(id): frame(solid(100, 100, 0, 255, 0))]
        let plan = CompositionPlan.make(layout: layout, canvas: PixelSize(width: 100, height: 100), output: compositor.outputSize,
                                        frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        let output = try #require(compositor.render(plan, frames: frames))
        #expect(near(pixel(output, 1, 1), (255, 0, 0)))
        #expect(near(pixel(output, 50, 50), (0, 255, 0)))
        #expect(near(pixel(output, 50, 1), (0, 0, 255), tolerance: 12))
        #expect(near(pixel(output, 98, 50), (0, 0, 255), tolerance: 12))
        #expect(near(pixel(output, 50, 9), (0, 255, 0)))
    }

    @Test func theOutputIsScaledDownFromTheCanvas() throws {
        let compositor = try Compositor(outputSize: PixelSize(width: 100, height: 50))
        let frames = [SourceKey.base: frame(makeBuffer(400, 200) { x, _ in x < 200 ? (255, 0, 0) : (0, 0, 255) })]
        let plan = CompositionPlan.make(layout: RecordingLayout(), canvas: PixelSize(width: 400, height: 200), output: compositor.outputSize,
                                        frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        let output = try #require(compositor.render(plan, frames: frames))
        #expect(CVPixelBufferGetWidth(output) == 100)
        #expect(near(pixel(output, 20, 25), (255, 0, 0)))
        #expect(near(pixel(output, 80, 25), (0, 0, 255)))
    }

    @Test func borderColorsParse() {
        #expect(Compositor.color(hex: "#FF000080").alpha < 0.51)
        #expect(Compositor.color(hex: "nonsense") == .white)
    }
}
