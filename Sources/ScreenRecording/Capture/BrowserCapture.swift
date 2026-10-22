import AppKit
import Foundation
import os
import WebKit

/// A web page rendered off-screen at the source's pixel size and captured like a window (spec 5.4.2).
public final class BrowserCapture: VideoCapture, @unchecked Sendable {
    private let url: URL
    private let pixelSize: PixelSize
    private let frameRate: Int
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// A stop while the page's window opens or its capture starts wins (`CaptureStartGate`).
    private let gate = CaptureStartGate()

    private struct State {
        var host: BrowserHost?
        /// The page's capture: the one that started, or the attempt under way, so a stop reaches it too.
        var capture: ScreenCapture?
    }

    public init(url: URL, pixelSize: PixelSize, frameRate: Int = 60) {
        self.url = url
        self.pixelSize = pixelSize
        self.frameRate = frameRate
    }

    /// A stop that comes before or while this runs leaves neither the page's window nor its capture behind.
    public func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        do {
            try gate.check()
            let host = await BrowserHost(url: url, pixelSize: pixelSize)
            state.withLock { $0.host = host }
            try gate.check()
            let windowID = await host.windowID
            // A new window takes a moment to show up in ScreenCaptureKit's list.
            var lastError: (any Error)?
            var started = false
            for _ in 0..<10 {
                try gate.check()
                let capture = ScreenCapture(target: .window(windowID), showsCursor: false, frameRate: frameRate)
                state.withLock { $0.capture = capture }
                do {
                    try await capture.start(deliver: deliver)
                    started = true
                    break
                } catch {
                    lastError = error
                    try gate.check()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard started else { throw lastError ?? CaptureError.unavailable("The web page couldn\u{2019}t be captured.") }
            try await gate.finish { await tearDown() }
        } catch {
            await tearDown()
            throw error
        }
    }

    public func stop() async {
        gate.close()
        await tearDown()
    }

    /// Stops the page's capture and closes its window, whatever of them is there. Running it again finds nothing.
    private func tearDown() async {
        let (capture, host) = state.withLock { state in
            defer { state = State() }
            return (state.capture, state.host)
        }
        await capture?.stop()
        await host?.close()
    }
}

/// The off-screen window that holds a browser source's page.
@MainActor
final class BrowserHost {
    let window: NSWindow
    let webView: WKWebView

    init(url: URL, pixelSize: PixelSize) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: max(16, CGFloat(pixelSize.width) / scale), height: max(16, CGFloat(pixelSize.height) / scale))
        // Far outside every display: never seen, still rendered and capturable as a window.
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window.contentView = webView
        webView.load(URLRequest(url: url))
        window.orderFrontRegardless()
    }

    var windowID: UInt32 { UInt32(window.windowNumber) }

    func close() {
        webView.stopLoading()
        window.orderOut(nil)
        window.close()
    }
}
