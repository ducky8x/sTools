import Foundation
import Testing
@testable import ScreenRecording

@Suite struct LayoutMathTests {
    @Test func fitKeepsTheAspectRatioAndCenters() {
        let fitted = LayoutMath.fit(PixelSize(width: 1600, height: 900), in: PixelRect(x: 0, y: 0, width: 400, height: 400))
        #expect(fitted == PixelRect(x: 0, y: 87.5, width: 400, height: 225))
        #expect(LayoutMath.fit(PixelSize(width: 0, height: 10), in: PixelRect(x: 5, y: 5, width: 10, height: 10)).isEmpty)
    }

    @Test func cropRectTrimsFractionsOfTheSource() {
        let rect = LayoutMath.cropRect(sourceSize: PixelSize(width: 1000, height: 500), crop: CropInsets(left: 0.1, top: 0.2, right: 0.3, bottom: 0))
        #expect(rect == PixelRect(x: 100, y: 100, width: 600, height: 400))
    }

    @Test func croppingNeverRemovesTheLastTwoPercent() {
        let crop = CropInsets(left: 0.9, top: -1, right: 0.9, bottom: .nan).clamped()
        #expect(abs(crop.left + crop.right - (1 - CropInsets.minimumVisibleFraction)) < 1e-9)
        #expect(crop.top == 0 && crop.bottom == 0)
    }

    @Test func cropFieldsRoundTripThroughPixels() {
        let size = PixelSize(width: 1920, height: 1080)
        let crop = CropInsets(left: 192, top: 108, right: 0, bottom: 54, of: size)
        let pixels = crop.pixels(of: size)
        #expect(pixels.left == 192 && pixels.top == 108 && pixels.right == 0 && pixels.bottom == 54)
    }

    @Test func contentRectFitsTheCroppedPartIntoTheFrame() {
        let rect = LayoutMath.contentRect(
            sourceSize: PixelSize(width: 1000, height: 1000), crop: CropInsets(left: 0, top: 0.5, right: 0, bottom: 0),
            in: PixelRect(x: 0, y: 0, width: 200, height: 200))
        #expect(rect == PixelRect(x: 0, y: 50, width: 200, height: 100))
    }

    @Test func clampPullsAFrameInsideTheCanvas() {
        let canvas = PixelSize(width: 1920, height: 1080)
        #expect(LayoutMath.clamp(PixelRect(x: -50, y: 1000, width: 400, height: 300), to: canvas) == PixelRect(x: 0, y: 780, width: 400, height: 300))
        #expect(LayoutMath.clamp(PixelRect(x: 0, y: 0, width: 4000, height: 2), to: canvas) == PixelRect(x: 0, y: 0, width: 1920, height: 16))
        #expect(LayoutMath.clamp(PixelRect(x: .nan, y: .infinity, width: 100, height: 100), to: canvas).x == 0)
    }

    @Test func aNewSourceGoesBottomRightAtAThirdOfTheCanvas() {
        let frame = LayoutMath.defaultFrame(forContent: PixelSize(width: 1280, height: 720), canvas: PixelSize(width: 1920, height: 1080))
        #expect(frame.width == 640 && frame.height == 360)
        #expect(frame.maxX == 1920 - 22 && frame.maxY == 1080 - 22)
    }

    @Test func canvasAndOutputSizesAreEvenAndNeverUpscaled() {
        #expect(LayoutMath.canvasSize(.minecraftDisplay, minecraftDisplay: PixelSize(width: 3025, height: 1965)) == PixelSize(width: 3024, height: 1964))
        #expect(LayoutMath.canvasSize(.minecraftDisplay, minecraftDisplay: PixelSize(width: 0, height: 0)) == PixelSize(width: 1920, height: 1080))
        #expect(LayoutMath.canvasSize(.custom(PixelSize(width: 1281, height: 721)), minecraftDisplay: .init(width: 1, height: 1)) == PixelSize(width: 1280, height: 720))
        #expect(LayoutMath.outputSize(.p1080, canvas: PixelSize(width: 3024, height: 1964)) == PixelSize(width: 1662, height: 1080))
        #expect(LayoutMath.outputSize(.p1440, canvas: PixelSize(width: 1920, height: 1080)) == PixelSize(width: 1920, height: 1080))
        #expect(LayoutMath.outputSize(.native, canvas: PixelSize(width: 2560, height: 1440)) == PixelSize(width: 2560, height: 1440))
    }
}

@Suite struct SnapEngineTests {
    let canvas = PixelSize(width: 1000, height: 600)

    @Test func aMovedFrameCatchesTheCanvasEdgeAndCenter() {
        let result = SnapEngine.snapMove(PixelRect(x: 5, y: 196, width: 100, height: 200), canvas: canvas, others: [])
        #expect(result.frame == PixelRect(x: 0, y: 200, width: 100, height: 200))
        #expect(result.guides.contains(SnapGuide(axis: .vertical, position: 0, target: .canvasEdge)))
        #expect(result.guides.contains(SnapGuide(axis: .horizontal, position: 300, target: .canvasCenter)))
    }

    @Test func aMovedFrameCatchesAnotherSource() {
        let other = PixelRect(x: 500, y: 100, width: 200, height: 100)
        let result = SnapEngine.snapMove(PixelRect(x: 704, y: 400, width: 100, height: 50), canvas: canvas, others: [other])
        #expect(result.frame.minX == 700)
        #expect(result.guides.contains(SnapGuide(axis: .vertical, position: 700, target: .sourceEdge)))
    }

    @Test func farAwayFramesDoNotMove() {
        let frame = PixelRect(x: 220, y: 130, width: 100, height: 50)
        #expect(SnapEngine.snapMove(frame, canvas: canvas, others: []).frame == frame)
        #expect(SnapEngine.snapMove(frame, canvas: canvas, others: []).guides.isEmpty)
    }

    @Test func resizingSnapsOnlyTheMovingEdges() {
        let result = SnapEngine.snapResize(
            PixelRect(x: 100, y: 100, width: 395, height: 100), edges: [.right], canvas: canvas, others: [])
        #expect(result.frame == PixelRect(x: 100, y: 100, width: 400, height: 100))
        let tiny = SnapEngine.snapResize(PixelRect(x: 100, y: 100, width: 3, height: 100), edges: [.left], canvas: canvas, others: [])
        #expect(tiny.frame.width == LayoutMath.minimumFrameSide && tiny.frame.maxX == 103)
    }
}

@Suite struct RecordingLayoutTests {
    private func source(_ title: String) -> VideoSource {
        VideoSource(kind: .browser(url: title), frame: CanvasRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }

    @Test func addingStacksOnTopAndReorderingRenumbers() {
        var layout = RecordingLayout()
        let a = source("a"), b = source("b"), c = source("c")
        layout.add(a); layout.add(b); layout.add(c)
        #expect(layout.orderedVideoSources.map(\.id) == [a.id, b.id, c.id])
        layout.bringToFront(a.id)
        #expect(layout.orderedVideoSources.map(\.id) == [b.id, c.id, a.id])
        layout.sendToBack(c.id)
        #expect(layout.orderedVideoSources.map(\.id) == [c.id, b.id, a.id])
        layout.moveForward(c.id)
        #expect(layout.orderedVideoSources.map(\.id) == [b.id, c.id, a.id])
        layout.moveBackward(a.id)
        #expect(layout.orderedVideoSources.map(\.id) == [b.id, a.id, c.id])
        #expect(layout.orderedVideoSources.map(\.zIndex) == [0, 1, 2])
    }

    @Test func removingABrowserSourceRemovesItsAudio() {
        var layout = RecordingLayout()
        let page = source("https://example.com")
        layout.add(page)
        layout.add(AudioSource(kind: .browser(videoSourceID: page.id), name: "Page"))
        layout.add(AudioSource(kind: .microphone(uniqueID: "mic"), name: "Mic"))
        layout.removeVideoSource(page.id)
        #expect(layout.videoSources.isEmpty)
        #expect(layout.audioSources.map(\.name) == ["Mic"])
    }

    @Test func sanitizePullsValuesIntoRange() {
        var layout = RecordingLayout(minecraftAudioVolume: 9)
        var bad = source("x")
        bad.frame = CanvasRect(x: -0.01, y: -0.01, width: 2.6, height: 0.001)
        bad.opacity = 3
        bad.cornerRadius = -4
        bad.border.width = .nan
        layout.videoSources = [bad]
        layout.add(AudioSource(kind: .microphone(uniqueID: "m"), name: "Mic", volume: -2))
        layout.sanitize()
        // Inside the canvas, and at least 16 pixels of a 1920 × 1080 canvas tall.
        #expect(layout.videoSources[0].frame == CanvasRect(x: 0, y: 0, width: 1, height: CanvasRect.minimumHeight))
        #expect(CanvasMapping(PixelSize(width: 1920, height: 1080)).rect(layout.videoSources[0].frame).pixelAligned == PixelRect(x: 0, y: 0, width: 1920, height: 16))
        #expect(layout.videoSources[0].opacity == 1 && layout.videoSources[0].cornerRadius == 0 && layout.videoSources[0].border.width == 0)
        #expect(layout.audioSources[0].volume == 0)
        #expect(layout.minecraftAudioVolume == AudioSource.volumeRange.upperBound)
    }

    @Test func layoutsRoundTripAndToleratePartialFiles() throws {
        var layout = RecordingLayout(includesMinecraftAudio: false)
        layout.add(VideoSource(kind: .window(WindowReference(windowID: 7, appName: "Discord", bundleID: "com.hnc.Discord", title: "Voice")),
                               frame: CanvasRect(x: 0.001, y: 0.002, width: 0.3, height: 0.2), crop: CropInsets(left: 0.1), opacity: 0.8, cornerRadius: 0.012,
                               border: SourceBorder(width: 0.002, colorHex: "#D9AE52")))
        layout.add(VideoSource(kind: .camera(CameraReference(uniqueID: "cam", name: "FaceTime")), frame: CanvasRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        layout.add(VideoSource(kind: .display(DisplayReference(displayID: 2, name: "LG")), frame: CanvasRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        layout.add(AudioSource(kind: .app(bundleID: "com.hnc.Discord"), name: "Discord", volume: 0.5))
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(RecordingLayout.self, from: data) == layout)
        let partial = try JSONDecoder().decode(RecordingLayout.self, from: Data(#"{"videoSources": [{"kind": {"type": "browser", "url": "x"}, "frame": {"x": 0, "y": 0, "width": 0.1, "height": 0.1}}]}"#.utf8))
        #expect(partial.videoSources.first?.opacity == 1)
        #expect(partial.includesMinecraftAudio)
    }
}
