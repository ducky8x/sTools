import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import STPlatform

public enum CaptureError: LocalizedError, Equatable {
    case notFound(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) isn\u{2019}t there any more."
        case .unavailable(let reason): reason
        }
    }
}

/// One ScreenCaptureKit stream (spec 5.4.2): a single window, a whole display, or the base layer (Minecraft's
/// window plus sTools' overlay and backdrop windows, on Minecraft's display).
public final class ScreenCapture: NSObject, VideoCapture, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum Target: Sendable, Equatable {
        case window(UInt32)
        case display(UInt32)
        /// Minecraft's window plus sTools' overlay and backdrop panels.
        case base(minecraftWindowID: UInt32)
    }

    private let target: Target
    private let showsCursor: Bool
    private let frameRate: Int
    private let queue = DispatchQueue(label: "sTools.capture.screen", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private var refresher: Task<Void, Never>?

    /// ScreenCaptureKit isn't annotated for concurrency; a stream is safe to start, stop and update from any task.
    private final class StreamBox: @unchecked Sendable {
        let stream: SCStream
        init(_ stream: SCStream) { self.stream = stream }
    }

    private struct State {
        var stream: StreamBox?
        var deliver: (@Sendable (VideoCaptureEvent) -> Void)?
        var includedWindowIDs: Set<UInt32> = []
        /// The size the stream was last asked to run at.
        var requestedSize: PixelSize?
    }

    public init(target: Target, showsCursor: Bool, frameRate: Int = 60) {
        self.target = target
        self.showsCursor = showsCursor
        self.frameRate = frameRate
    }

    public func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let (overlays, excluded) = await MainActor.run {
            (Set(OverlayPanel.visibleWindowNumbers()), Set(OverlayPanel.captureExcludedWindowNumbers()))
        }
        let (filter, included) = try makeFilter(content, overlays: overlays, excluded: excluded)
        let scale = CGFloat(filter.pointPixelScale)
        let size = PixelSize(width: max(2, Int((filter.contentRect.width * scale).rounded())),
                             height: max(2, Int((filter.contentRect.height * scale).rounded())))
        let configuration = Self.configuration(size: size, frameRate: frameRate, showsCursor: showsCursor)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let box = StreamBox(stream)
        state.withLock {
            $0.stream = box
            $0.deliver = deliver
            $0.includedWindowIDs = included
            $0.requestedSize = size
        }
        try await box.stream.startCapture()
        if case .base = target { startRefreshing() }
    }

    private static func configuration(size: PixelSize, frameRate: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 5
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        return configuration
    }

    /// Runs the stream at `size`, once per size: a window resized past the stream, or one whose display changed
    /// backing scale, is then captured one to one again instead of scaled to the size it started at.
    private func resize(to size: PixelSize) {
        let box: StreamBox? = state.withLock { state in
            guard state.requestedSize != size, let stream = state.stream else { return nil }
            state.requestedSize = size
            return stream
        }
        guard let box else { return }
        let frameRate = frameRate, showsCursor = showsCursor
        Task {
            try? await box.stream.updateConfiguration(Self.configuration(size: size, frameRate: frameRate, showsCursor: showsCursor))
        }
    }

    public func stop() async {
        refresher?.cancel()
        refresher = nil
        let box = state.withLock { state -> StreamBox? in
            defer { state.stream = nil; state.deliver = nil }
            return state.stream
        }
        try? await box?.stream.stopCapture()
    }

    // MARK: Filters

    /// `excluded` lists sTools panels that must never be recorded (the hotkey confirmation); a whole display
    /// would otherwise pick them up.
    private func makeFilter(_ content: SCShareableContent, overlays: Set<UInt32>,
                            excluded: Set<UInt32> = []) throws -> (SCContentFilter, Set<UInt32>) {
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.notFound("The window") }
            return (SCContentFilter(desktopIndependentWindow: window), [id])
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.notFound("The display") }
            let hidden = content.windows.filter { excluded.contains($0.windowID) }
            return (SCContentFilter(display: display, excludingWindows: hidden), [])
        case .base(let minecraftID):
            guard let minecraft = content.windows.first(where: { $0.windowID == minecraftID }) else {
                throw CaptureError.notFound("Minecraft\u{2019}s window")
            }
            guard let display = Self.display(for: minecraft.frame, in: content.displays) else {
                throw CaptureError.notFound("Minecraft\u{2019}s display")
            }
            let windows = content.windows.filter { $0.windowID == minecraftID || overlays.contains($0.windowID) }
            return (SCContentFilter(display: display, including: windows), Set(windows.map(\.windowID)))
        }
    }

    /// The display that holds most of `frame` (Core Graphics global coordinates, as `SCWindow.frame` is).
    static func display(for frame: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays.max { lhs, rhs in
            let a = lhs.frame.intersection(frame), b = rhs.frame.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
    }

    /// sTools' overlays come and go as tools are switched; the base layer's window list follows every 2 s.
    private func startRefreshing() {
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let overlays = await MainActor.run { Set(OverlayPanel.visibleWindowNumbers()) }
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                      let (filter, included) = try? self.makeFilter(content, overlays: overlays) else { continue }
                let (box, changed) = self.state.withLock { ($0.stream, $0.includedWindowIDs != included) }
                guard changed, let box else { continue }
                try? await box.stream.updateContentFilter(filter)
                self.state.withLock { $0.includedWindowIDs = included }
            }
        }
    }

    // MARK: Output

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else { return }
        let deliver = state.withLock { $0.deliver }
        switch status {
        case .complete:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let bufferSize = PixelSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            let metadata = FrameMetadata(info)
            let frame = VideoFrame(
                pixelBuffer: pixelBuffer, contentRect: metadata.contentRect(in: bufferSize),
                hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            deliver?(.frame(frame))
            if let size = metadata.streamSize(for: bufferSize) { resize(to: size) }
        case .suspended:
            deliver?(.minimized(true))
        case .started, .idle, .blank, .stopped:
            break
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let deliver = state.withLock { $0.deliver }
        deliver?(.ended(error.localizedDescription))
    }

}

/// What ScreenCaptureKit says about where a frame's content is (WWDC22 "Take ScreenCaptureKit to the next level"),
/// as plain values, so it's worked out (and tested) without a stream.
///
/// The content rect is the region of the stream's output the content covers, in points of that output; the scale
/// factor turns those points into the buffer's pixels (WebRTC and OBS crop the same way). The content scale says
/// how much the content was scaled to fit the output: under 1 when it's bigger than the stream (a window resized
/// past it, or its display gone from 1x to 2x). It doesn't move the content rect; it gives the content's own size.
struct FrameMetadata: Equatable, Sendable {
    var contentRect: CGRect?
    var scaleFactor: Double?
    var contentScale: Double?

    init(contentRect: CGRect? = nil, scaleFactor: Double? = nil, contentScale: Double? = nil) {
        self.contentRect = contentRect
        self.scaleFactor = scaleFactor
        self.contentScale = contentScale
    }

    init(_ info: [SCStreamFrameInfo: Any]) {
        self.init(
            contentRect: (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) },
            scaleFactor: (info[.scaleFactor] as? NSNumber)?.doubleValue,
            contentScale: (info[.contentScale] as? NSNumber)?.doubleValue)
    }

    private static func usable(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Where the content sits in a buffer `bufferSize` big, in pixels, kept inside the buffer: the content rect
    /// times the scale factor. Without a usable scale factor (reported on mixed Retina and non-Retina setups) it's
    /// the scale at which the content fills the buffer along one side, which is exact while the content was fitted
    /// to the stream or the stream runs at the content's size. Nil without a usable content rect: the whole
    /// buffer is used.
    func contentRect(in bufferSize: PixelSize) -> PixelRect? {
        guard let rect = contentRect, !bufferSize.isEmpty,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0
        else { return nil }
        let width = Double(bufferSize.width), height = Double(bufferSize.height)
        let scale = Self.usable(scaleFactor) ?? min(width / rect.width, height / rect.height)
        let left = max(0, rect.minX * scale), top = max(0, rect.minY * scale)
        let right = min(width, rect.maxX * scale), bottom = min(height, rect.maxY * scale)
        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The size the stream should run at for its content to fill it one to one (the content's own pixel size:
    /// what it covers in the buffer divided by the content scale, shrunk to the largest canvas side if need be), or
    /// nil when it already does, within 2 pixels.
    func streamSize(for bufferSize: PixelSize) -> PixelSize? {
        guard let content = contentRect(in: bufferSize) else { return nil }
        let scale = Self.usable(contentScale) ?? 1
        var width = content.width / scale, height = content.height / scale
        let limit = Double(RecordingOptions.canvasSideRange.upperBound)
        if max(width, height) > limit {
            let shrink = limit / max(width, height)
            width *= shrink
            height *= shrink
        }
        width = max(2, width.rounded())
        height = max(2, height.rounded())
        guard abs(width - Double(bufferSize.width)) > 2 || abs(height - Double(bufferSize.height)) > 2 else { return nil }
        return PixelSize(width: Int(width), height: Int(height))
    }
}
