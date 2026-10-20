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
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 5
        configuration.showsCursor = showsCursor
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let box = StreamBox(stream)
        state.withLock {
            $0.stream = box
            $0.deliver = deliver
            $0.includedWindowIDs = included
        }
        try await box.stream.startCapture()
        if case .base = target { startRefreshing() }
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
            let frame = VideoFrame(
                pixelBuffer: pixelBuffer, contentRect: Self.contentRect(info),
                hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            deliver?(.frame(frame))
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

    /// Where the content sits in the buffer, in pixels: the frame's content rect (points) times its scale
    /// factor, the way Apple's capture sample and WebRTC crop it.
    static func contentRect(_ info: [SCStreamFrameInfo: Any]) -> PixelRect? {
        guard let dictionary = info[.contentRect], let rect = CGRect(dictionaryRepresentation: dictionary as! CFDictionary) else { return nil }
        let scale = (info[.scaleFactor] as? CGFloat) ?? 1
        return PixelRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
}
