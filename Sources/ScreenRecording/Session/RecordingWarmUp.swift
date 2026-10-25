import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// Readies, while Screen Recording is armed, what a recording's first frame would otherwise wait for (spec 5.4.4):
/// the video encoder, which VideoToolbox loads the first time a writer opens, and Core Image on Metal, whose pipeline
/// is built at the first render. Nothing is captured, nothing shows, nothing asks for a permission, and nothing is
/// left on disk.
public enum RecordingWarmUp {
    /// The codecs whose encoder was already readied in this launch: loading one again gains nothing.
    final class Warmed: @unchecked Sendable {
        private let codecs = OSAllocatedUnfairLock(initialState: Set<VideoCodec>())

        init() {}

        /// True the first time `codec` is claimed in this launch, so only that arming warms its encoder.
        func claim(_ codec: VideoCodec) -> Bool {
            codecs.withLock { $0.insert(codec).inserted }
        }
    }

    static let warmed = Warmed()

    /// The size the throwaway writer encodes at: small, since only loading the encoder matters.
    private static let encoderSize = PixelSize(width: 320, height: 180)

    /// Readies `codec`'s encoder once per launch, with a throwaway writer in a temporary folder of its own that's
    /// removed after.
    static func warmEncoder(codec: VideoCodec) {
        guard warmed.claim(codec) else { return }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "sTools warm-up \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        _ = startAndCancelWriter(codec: codec, in: folder)
    }

    /// Opens a movie writer in `folder` with a recording's video settings for `codec`, hands it one black frame so
    /// its encoder starts, and cancels it, removing its file. True when the encoder took the frame.
    static func startAndCancelWriter(codec: VideoCodec, in folder: URL) -> Bool {
        let url = folder.appending(path: "warm-up \(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = WriterConfiguration(
            directory: folder, baseName: url.deletingPathExtension().lastPathComponent, canvas: encoderSize, codec: codec)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: RecordingWriter.videoSettings(for: configuration, allowsHardwareEncoder: true))
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: encoderSize.width,
                kCVPixelBufferHeightKey as String: encoderSize.height,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        var appended = false
        if input.isReadyForMoreMediaData, let frame = blackFrame(encoderSize) {
            appended = adaptor.append(frame, withPresentationTime: .zero)
        }
        writer.cancelWriting()
        return appended
    }

    /// A compositor for `outputSize` that has drawn once, so Core Image's Metal pipeline (and the kernels `layout`'s
    /// sources use: crop, scale, opacity, rounded corners, borders) is built before the recording's first frame, and
    /// has made one pass-through copy, so VideoToolbox's is too.
    /// Nil when there's no Metal device; the recording then makes its own and says why it can't.
    static func compositor(outputSize: PixelSize, layout: RecordingLayout = RecordingLayout(), canvas: PixelSize? = nil) -> Compositor? {
        guard let compositor = try? Compositor(outputSize: outputSize) else { return nil }
        let size = compositor.outputSize
        guard let frame = blackFrame(PixelSize(width: 64, height: 36)) else { return compositor }
        let still = VideoFrame(pixelBuffer: frame, hostTime: .zero)
        var frames: [SourceKey: VideoFrame] = [.base: still]
        for source in layout.videoSources { frames[.source(source.id)] = still }
        let plan = CompositionPlan.make(
            layout: layout, canvas: canvas ?? size, output: size, frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        _ = compositor.render(plan, frames: frames)
        compositor.preparePassThrough(with: frame)
        return compositor
    }

    private static func blackFrame(_ size: PixelSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * size.height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
