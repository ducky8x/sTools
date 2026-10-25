import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ScreenRecording

/// An IOSurface-backed BGRA frame with a pattern that has edges and gradients in every channel, optionally tagged
/// the way a capture's frames can be.
private func patternBuffer(_ size: PixelSize, tags: [CFString: CFString] = [:], seed: Int = 0) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<size.height {
        for x in 0..<size.width {
            let p = base + y * stride + x * 4
            p[0] = UInt8(truncatingIfNeeded: x * 3 + seed)
            p[1] = UInt8(truncatingIfNeeded: (x / 8 + y / 8) % 2 == 0 ? 220 : 30)
            p[2] = UInt8(truncatingIfNeeded: y * 5 + seed * 7)
            p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    for (key, value) in tags { CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate) }
    return pixelBuffer
}

/// Tags a ScreenCaptureKit frame asked for in sRGB may carry.
private var captureTags: [CFString: CFString] { [
    kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
    kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
] }

/// Each decoded frame of a movie as 4:2:0 planes (luma, then chroma), and the video track's color tags.
private func decodedFrames(of url: URL) async throws -> (frames: [[UInt8]], tags: [String]) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let description = try #require(try await track.load(.formatDescriptions).first)
    let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
    let tags = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
        .map { "\(extensions[$0 as String] ?? "none")" }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    reader.add(output)
    #expect(reader.startReading())
    var frames: [[UInt8]] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        var bytes: [UInt8] = []
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                bytes.append(contentsOf: UnsafeBufferPointer(start: base + row * rowBytes, count: width))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        frames.append(bytes)
    }
    return (frames, tags)
}

/// Writes `pictures` as a 30 fps movie in `directory`, waiting for the encoder so none is dropped.
private func writeMovie(_ pictures: [CVPixelBuffer], size: PixelSize, name: String, in directory: URL) async throws -> URL {
    var configuration = WriterFixture.configuration(directory, base: name, audio: [])
    configuration.canvas = size
    let writer = RecordingWriter(configuration: configuration, freeSpace: FakeFreeSpace(.max), readinessOverride: nil)
    try writer.start(at: .zero)
    for (index, picture) in pictures.enumerated() {
        while !writer.canAcceptFrame { try await Task.sleep(for: .milliseconds(2)) }
        #expect(writer.append(frame: picture, at: CMTime(value: CMTimeValue(index), timescale: 30)) == .written)
    }
    let result = await writer.finish()
    return try #require(result.files.first)
}

@Suite("Pass-through") struct PassThroughTests {
    let canvas = PixelSize(width: 1920, height: 1080)

    private func plan(_ layout: RecordingLayout = RecordingLayout(), canvas: PixelSize? = nil, output: PixelSize? = nil,
                      frames: [SourceKey: CompositionPlan.FrameGeometry]) -> CompositionPlan {
        CompositionPlan.make(layout: layout, canvas: canvas ?? self.canvas, output: output ?? canvas ?? self.canvas, frames: frames)
    }

    @Test func minecraftAloneAtTheOutputSizePassesThrough() {
        let plan = plan(frames: [.base: .init(bufferSize: canvas)])
        #expect(plan.passThroughSource(bufferSizes: [.base: canvas]) == .base)
    }

    @Test func anythingThatHasToBeDrawnDoesNot() {
        // The output scaled down from the canvas (1080p of a 4K display).
        let big = PixelSize(width: 3840, height: 2160)
        #expect(plan(canvas: big, output: canvas, frames: [.base: .init(bufferSize: big)])
            .passThroughSource(bufferSizes: [.base: big]) == nil)
        // Black bars: a custom canvas wider than Minecraft's picture.
        let wide = PixelSize(width: 2000, height: 1080)
        #expect(plan(canvas: wide, frames: [.base: .init(bufferSize: canvas)]).passThroughSource(bufferSizes: [.base: canvas]) == nil)
        // Only part of the buffer holds the picture (a resized window).
        #expect(plan(frames: [.base: .init(bufferSize: canvas, contentRect: PixelRect(x: 0, y: 0, width: 1600, height: 900))])
            .passThroughSource(bufferSizes: [.base: canvas]) == nil)
        // A second source on top.
        var layout = RecordingLayout()
        let camera = VideoSource(kind: .camera(CameraReference(uniqueID: "c", name: "Camera")),
                                 frame: PixelRect(x: 1500, y: 800, width: 320, height: 180), on: canvas)
        layout.add(camera)
        let small = PixelSize(width: 320, height: 180)
        #expect(plan(layout, frames: [.base: .init(bufferSize: canvas), .source(camera.id): .init(bufferSize: small)])
            .passThroughSource(bufferSizes: [.base: canvas, .source(camera.id): small]) == nil)
    }

    @Test func aWholeCanvasSourcePassesThroughOnlyWhenNothingIsDrawnOnIt() {
        func layout(opacity: Double = 1, corner: Double = 0, border: Double = 0) -> (RecordingLayout, UUID) {
            var layout = RecordingLayout()
            let source = VideoSource(kind: .display(DisplayReference(displayID: 1, name: "Display")),
                                     frame: PixelRect(x: 0, y: 0, width: 1920, height: 1080), on: canvas,
                                     opacity: opacity, cornerRadius: corner, border: SourceBorder(width: border))
            layout.add(source)
            return (layout, source.id)
        }
        for (case_, passes) in [(layout(), true), (layout(opacity: 0.8), false), (layout(corner: 12), false), (layout(border: 4), false)] {
            let (layout, id) = case_
            let plan = plan(layout, frames: [.source(id): .init(bufferSize: canvas)])
            #expect((plan.passThroughSource(bufferSizes: [.source(id): canvas]) != nil) == passes)
        }
    }

    @Test func theCompositorHandsOnAnUntaggedCopyInTheEncodersFormat() throws {
        let compositor = try Compositor(outputSize: canvas)
        let source = patternBuffer(canvas, tags: captureTags)
        let frames: [SourceKey: VideoFrame] = [.base: VideoFrame(pixelBuffer: source, hostTime: .zero)]
        let copy = try #require(compositor.passThrough(plan(frames: frames.mapValues(CompositionPlan.FrameGeometry.init)), frames: frames))
        #expect(CVPixelBufferGetPixelFormatType(copy) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetWidth(copy) == canvas.width && CVPixelBufferGetHeight(copy) == canvas.height)
        #expect((CVBufferCopyAttachments(copy, .shouldPropagate) as? [String: Any] ?? [:]).isEmpty)
        // The captured frame keeps its own tags.
        #expect(CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, nil) != nil)
        // A plan that draws gets nothing.
        let wide = PixelSize(width: 2000, height: 1080)
        let drawn = CompositionPlan.make(layout: RecordingLayout(), canvas: wide, output: wide, frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        #expect(try Compositor(outputSize: wide).passThrough(drawn, frames: frames) == nil)
    }

    /// The point of the whole path: a movie made of passed-through frames is the movie the compositor's pictures make,
    /// pixel for pixel and tag for tag, whether or not the captured frames carry color tags.
    @Test(arguments: [false, true])
    func passedThroughFramesMakeTheSameMovieAsDrawnOnes(tagged: Bool) async throws {
        let directory = try WriterFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = PixelSize(width: 640, height: 360)
        let compositor = try Compositor(outputSize: size)
        var drawn: [CVPixelBuffer] = [], passed: [CVPixelBuffer] = []
        for index in 0..<4 {
            let frames: [SourceKey: VideoFrame] = [
                .base: VideoFrame(pixelBuffer: patternBuffer(size, tags: tagged ? captureTags : [:], seed: index * 9), hostTime: .zero),
            ]
            let plan = CompositionPlan.make(layout: RecordingLayout(), canvas: size, output: size,
                                            frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
            drawn.append(try #require(compositor.render(plan, frames: frames)))
            passed.append(try #require(compositor.passThrough(plan, frames: frames)))
        }
        let a = try await decodedFrames(of: try await writeMovie(drawn, size: size, name: "drawn", in: directory))
        let b = try await decodedFrames(of: try await writeMovie(passed, size: size, name: "passed", in: directory))
        #expect(a.tags == ["none", "none", "none"])
        #expect(b.tags == a.tags)
        #expect(a.frames.count == 4 && b.frames.count == 4)
        for (x, y) in zip(a.frames, b.frames) {
            #expect(x.count == y.count)
            let largest = zip(x, y).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(largest == 0)
        }
    }
}

/// Core Image reads each frame's color space from its tags; the compositor works it out once per set of tags and
/// hands it over, which must give exactly the image Core Image makes on its own.
@Suite("Frame color spaces") struct FrameColorSpacesTests {
    private func buffer(_ format: OSType, tags: [CFString: CFTypeRef]) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, format, [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        for plane in 0..<max(1, CVPixelBufferGetPlaneCount(pixelBuffer)) {
            let planar = CVPixelBufferIsPlanar(pixelBuffer)
            let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) : CVPixelBufferGetBaseAddress(pixelBuffer))!
                .assumingMemoryBound(to: UInt8.self)
            let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) : CVPixelBufferGetBytesPerRow(pixelBuffer)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
            for row in 0..<rows {
                for x in 0..<rowBytes { base[row * rowBytes + x] = UInt8(truncatingIfNeeded: x * 7 + row * 13 + plane * 50) | (format == kCVPixelFormatType_32BGRA && x % 4 == 3 ? 255 : 0) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for (key, value) in tags { CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate) }
        return pixelBuffer
    }

    private func bytes(of image: CIImage, with context: CIContext) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64 * 36 * 4)
        context.render(image, toBitmap: &bytes, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 36),
                       format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }

    @Test func theImageIsTheOneCoreImageMakesFromTheTags() {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let srgb: [CFString: CFTypeRef] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
        ]
        let camera: [CFString: CFTypeRef] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        let p3: [CFString: CFTypeRef] = [kCVImageBufferCGColorSpaceKey: CGColorSpace(name: CGColorSpace.displayP3)!]
        let cases: [CVPixelBuffer] = [
            buffer(kCVPixelFormatType_32BGRA, tags: [:]),
            buffer(kCVPixelFormatType_32BGRA, tags: srgb),
            buffer(kCVPixelFormatType_32BGRA, tags: p3),
            buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, tags: camera),
        ]
        var spaces = FrameColorSpaces()
        for pixelBuffer in cases {
            for _ in 0..<2 {
                #expect(bytes(of: spaces.image(of: pixelBuffer), with: context) == bytes(of: CIImage(cvPixelBuffer: pixelBuffer), with: context))
            }
        }
        // Each set of tags is worked out once: the same tags give the very same color space, whatever other
        // attachments a frame carries.
        let again = buffer(kCVPixelFormatType_32BGRA, tags: srgb)
        CVBufferSetAttachment(again, "sTools frame number" as CFString, 7 as CFNumber, .shouldPropagate)
        let first = spaces.colorSpace(of: cases[1])
        #expect(first != nil)
        #expect(spaces.colorSpace(of: again) === first)
        #expect(spaces.colorSpace(of: cases[0]) == nil)
    }
}
