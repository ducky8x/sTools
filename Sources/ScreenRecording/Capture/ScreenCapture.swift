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
    /// A stop while the stream starts wins (`CaptureStartGate`).
    private let gate = CaptureStartGate()

    /// ScreenCaptureKit isn't annotated for concurrency; a stream is safe to start, stop and update from any task.
    private final class StreamBox: @unchecked Sendable {
        let stream: SCStream
        init(_ stream: SCStream) { self.stream = stream }
    }

    /// A notification observer's token, which may be removed from any thread.
    private final class ObserverBox: @unchecked Sendable {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
    }

    private struct State {
        var stream: StreamBox?
        var deliver: (@Sendable (VideoCaptureEvent) -> Void)?
        /// The windows the filter names: the ones the base layer includes, or the sTools panels a display leaves out.
        var filterWindowIDs: Set<UInt32> = []
        /// The size the stream was last asked to run at.
        var requestedSize: PixelSize?
        /// The observer of overlay panels showing and hiding (the base layer) or of excluded panels showing (a
        /// display).
        var overlayObserver: ObserverBox?
        /// The base layer's 2 s sweep of the window list.
        var refresher: Task<Void, Never>?
        /// Numbers the filter's refreshes in the order they read the window list, so an older one that finishes
        /// late never replaces a newer one's filter.
        var lastRefresh = 0
        var appliedRefresh = 0
        var overlayDebounce = OverlayRefreshDebounce()
    }

    /// The base layer's clock for folding overlay posts, the one `Task.sleep(for:)` waits on.
    private let refreshOrigin = ContinuousClock.now

    public init(target: Target, showsCursor: Bool, frameRate: Int = 60) {
        self.target = target
        self.showsCursor = showsCursor
        self.frameRate = frameRate
    }

    /// A stop that comes before or while this runs leaves no stream running: the start leaves off at the next await,
    /// or, once the stream started, stops it again before it returns (and throws `CancellationError`).
    public func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        try gate.check()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try gate.check()
        let (overlays, excluded) = await MainActor.run {
            (Set(OverlayPanel.visibleWindowNumbers()), Set(OverlayPanel.captureExcludedWindowNumbers()))
        }
        try gate.check()
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
            $0.filterWindowIDs = included
            $0.requestedSize = size
        }
        do {
            try await box.stream.startCapture()
        } catch {
            await tearDown()
            try gate.check()
            throw error
        }
        switch target {
        case .base: startRefreshing(on: OverlayPanel.capturableVisibilityDidChange, sweeping: true)
        case .display: startRefreshing(on: OverlayPanel.excludedFromCaptureDidShow, sweeping: false)
        case .window: break
        }
        // A stop during `startCapture` may have found the stream not yet running; it's stopped here by its own
        // reference, since that stop already took it from `state`.
        try await gate.finish {
            await tearDown()
            try? await box.stream.stopCapture()
        }
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

    /// Stops the stream for good; a start still under way leaves no stream running either.
    public func stop() async {
        gate.close()
        await tearDown()
    }

    /// Stops the stream stored so far and lets go of its observer, sweep and output. Running it again finds nothing.
    private func tearDown() async {
        let (box, observer, refresher) = state.withLock { state -> (StreamBox?, ObserverBox?, Task<Void, Never>?) in
            defer { state.stream = nil; state.deliver = nil; state.overlayObserver = nil; state.refresher = nil }
            return (state.stream, state.overlayObserver, state.refresher)
        }
        refresher?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer.token) }
        try? await box?.stream.stopCapture()
    }

    // MARK: Filters

    /// `excluded` lists sTools panels that must never be recorded (the hotkey confirmation, Timer Overlay with "Show in
    /// recordings" off); a whole display would otherwise pick them up. Also returns the windows the filter names.
    private func makeFilter(_ content: SCShareableContent, overlays: Set<UInt32>,
                            excluded: Set<UInt32> = []) throws -> (SCContentFilter, Set<UInt32>) {
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.notFound("The window") }
            return (SCContentFilter(desktopIndependentWindow: window), [id])
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.notFound("The display") }
            let hidden = content.windows.filter { excluded.contains($0.windowID) }
            return (SCContentFilter(display: display, excludingWindows: hidden), Set(hidden.map(\.windowID)))
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

    /// sTools' overlays come and go as tools are switched and as Timer Overlay pops up. The base layer's window list
    /// follows each panel that shows or hides (`OverlayPanel.capturableVisibilityDidChange`) about 50 ms later, and
    /// every 2 s as a backstop (plan decision 1). A display leaves out each panel excluded from capture that shows
    /// (`OverlayPanel.excludedFromCaptureDidShow`) the same way.
    private func startRefreshing(on name: Notification.Name, sweeping: Bool) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.overlaysChanged()
        }
        let box = ObserverBox(observer)
        state.withLock { $0.overlayObserver = box }
        guard sweeping else { return }
        let refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.refreshFilter()
            }
        }
        state.withLock { $0.refresher = refresher }
    }

    /// An overlay showed or hid: refresh once the debounce's delay has passed, unless a refresh already waits.
    private func overlaysChanged() {
        let elapsed = ContinuousClock.now - refreshOrigin
        let now = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let delay: TimeInterval? = state.withLock { state in
            guard state.stream != nil, state.overlayDebounce.noteChange(at: now) else { return nil }
            return state.overlayDebounce.delay
        }
        guard let delay else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.refreshFilter()
        }
    }

    /// Reads sTools' panels and gives the stream a new filter when the windows it names changed.
    private func refreshFilter() async {
        guard let refresh = state.withLock({ state -> Int? in
            guard state.stream != nil else { return nil }
            state.lastRefresh += 1
            return state.lastRefresh
        }) else { return }
        let (overlays, excluded) = await MainActor.run {
            (Set(OverlayPanel.visibleWindowNumbers()), Set(OverlayPanel.captureExcludedWindowNumbers()))
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let (filter, named) = try? makeFilter(content, overlays: overlays, excluded: excluded) else { return }
        let box: StreamBox? = state.withLock { state in
            guard refresh > state.appliedRefresh, state.filterWindowIDs != named, let stream = state.stream else { return nil }
            state.appliedRefresh = refresh
            return stream
        }
        guard let box else { return }
        do {
            try await box.stream.updateContentFilter(filter)
            state.withLock { state in
                if state.appliedRefresh == refresh { state.filterWindowIDs = named }
            }
        } catch {
            // The next post or sweep tries again.
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

/// Folds a burst of overlay show and hide posts into one refresh of the base layer's window list, `delay` after the
/// first post (plan decision 1). A post while that refresh still waits joins it, since the refresh reads the window
/// list after the post. A post once it's due needs a refresh of its own: the one before may have read the list
/// already. Times are seconds on one clock; tests pass their own.
struct OverlayRefreshDebounce: Equatable, Sendable {
    static let standardDelay: TimeInterval = 0.05

    let delay: TimeInterval
    /// When the waiting refresh reads the window list, if one waits.
    private(set) var dueTime: TimeInterval?

    init(delay: TimeInterval = Self.standardDelay) {
        self.delay = max(0, delay)
    }

    /// A post at `now`. True when it needs a refresh of its own, `delay` from now; false when it joins the waiting one.
    mutating func noteChange(at now: TimeInterval) -> Bool {
        if let dueTime, now < dueTime { return false }
        dueTime = now + delay
        return true
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
