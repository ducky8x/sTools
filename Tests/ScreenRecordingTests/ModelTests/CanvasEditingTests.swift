import Foundation
import Testing
@testable import ScreenRecording

@Suite struct CanvasEditingTests {
    let canvas = PixelSize(width: 1000, height: 600)
    let frame = PixelRect(x: 200, y: 100, width: 400, height: 200)

    private func source(crop: CropInsets = .zero) -> VideoSource {
        VideoSource(kind: .browser(url: "x"), frame: frame, on: canvas, crop: crop)
    }

    /// A result's frame in pixels of the test canvas, edges rounded to whole pixels.
    private func pixels(_ result: CanvasEditing.Result) -> PixelRect {
        CanvasMapping(canvas).rect(result.frame).pixelAligned
    }

    @Test func pressesFindCornersEdgesAndTheBody() {
        #expect(CanvasEditing.handle(at: (202, 98), frame: frame, tolerance: 6, cropping: false) == .resize([.left, .top]))
        #expect(CanvasEditing.handle(at: (600, 200), frame: frame, tolerance: 6, cropping: false) == .resize(.right))
        #expect(CanvasEditing.handle(at: (400, 300), frame: frame, tolerance: 6, cropping: true) == .crop(.bottom))
        #expect(CanvasEditing.handle(at: (300, 150), frame: frame, tolerance: 6, cropping: false) == .body)
        #expect(CanvasEditing.handle(at: (50, 50), frame: frame, tolerance: 6, cropping: false) == nil)
    }

    @Test func movingSnapsAndStaysOnTheCanvas() {
        let snapped = CanvasEditing.drag(.body, source: source(), by: (-196, 0), canvas: canvas, others: [], contentSize: nil)
        #expect(snapped.frame.minX == 0)
        #expect(!snapped.guides.isEmpty)
        let pushed = CanvasEditing.drag(.body, source: source(), by: (5000, 5000), canvas: canvas, others: [], contentSize: nil)
        #expect(pixels(pushed).maxX == 1000 && pixels(pushed).maxY == 600)
        #expect(abs(pushed.frame.maxX - 1) < 1e-9 && abs(pushed.frame.maxY - 1) < 1e-9)
    }

    @Test func theSnapDistanceScalesWithTheCanvas() {
        #expect(SnapEngine.threshold(for: PixelSize(width: 1920, height: 1080)) == 8)
        #expect(SnapEngine.threshold(for: PixelSize(width: 3840, height: 2160)) == 16)
        #expect(abs(SnapEngine.threshold(for: PixelSize(width: 1280, height: 720)) - 16.0 / 3) < 1e-12)
        #expect(SnapEngine.threshold(for: PixelSize(width: 1080, height: 1920)) == 8)
    }

    /// The same drag at 1x (a 1920 x 1080 canvas) and at 2x (3840 x 2160) snaps the same way, to the same place.
    @Test func snappingFeelsTheSameAt1xAnd2x() {
        let start = CanvasRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)
        let other = CanvasRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)
        let source = VideoSource(kind: .browser(url: "x"), frame: start)
        for (gap, snaps) in [(6.0, true), (10.0, false)] {
            var results: [CanvasEditing.Result] = []
            for canvas in [PixelSize(width: 1920, height: 1080), PixelSize(width: 3840, height: 2160)] {
                let k = Double(canvas.height) / 1080
                // Move the left edge to `gap` 1080p pixels from the canvas's left edge.
                let dx = (gap - 480) * k
                let move = CanvasEditing.drag(.body, source: source, by: (dx, 0), canvas: canvas, others: [other], contentSize: nil)
                #expect((move.frame.minX == 0) == snaps)
                // Resize the right edge to `gap` 1080p pixels short of the other source's left edge.
                let right = CanvasEditing.drag(.resize(.right), source: source, by: ((1152 - gap - 960) * k, 0), canvas: canvas,
                                               others: [other], contentSize: nil)
                #expect((abs(right.frame.maxX - 0.6) < 1e-9) == snaps)
                results.append(move)
            }
            #expect(abs(results[0].frame.minX - results[1].frame.minX) < 1e-9)
        }
    }

    @Test func resizingMovesOnlyTheDraggedEdges() {
        let result = CanvasEditing.drag(.resize(.right), source: source(), by: (53, 40), canvas: canvas, others: [], contentSize: nil)
        #expect(pixels(result) == PixelRect(x: 200, y: 100, width: 453, height: 200))
    }

    @Test func croppingFollowsThePointerAcrossTheContent() {
        // A 400×200 source drawn 400×200: dragging the left edge 100 px right crops a quarter.
        let result = CanvasEditing.drag(.crop(.left), source: source(), by: (100, 0), canvas: canvas, others: [], contentSize: PixelSize(width: 800, height: 400))
        #expect(abs(result.crop.left - 0.25) < 1e-9)
        #expect(result.frame == source().frame)
        let back = CanvasEditing.drag(.crop(.right), source: source(crop: CropInsets(right: 0.5)), by: (100, 0), canvas: canvas, others: [], contentSize: PixelSize(width: 800, height: 400))
        #expect(back.crop.right < 0.5)
    }
}
