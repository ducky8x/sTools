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
