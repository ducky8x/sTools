import AppKit
import Foundation
import WebKit

/// A web page rendered off-screen at the source's pixel size and captured like a window (spec 5.4.2).
public final class BrowserCapture: VideoCapture, @unchecked Sendable {
    private let url: URL
    private let pixelSize: PixelSize
    private let frameRate: Int
    private var host: BrowserHost?
    private var capture: ScreenCapture?

    public init(url: URL, pixelSize: PixelSize, frameRate: Int = 60) {
        self.url = url
        self.pixelSize = pixelSize
        self.frameRate = frameRate
    }

    public func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        let host = await BrowserHost(url: url, pixelSize: pixelSize)
        self.host = host
        let windowID = await host.windowID
        // A new window takes a moment to show up in ScreenCaptureKit's list.
        var lastError: (any Error)?
        for _ in 0..<10 {
            let capture = ScreenCapture(target: .window(windowID), showsCursor: false, frameRate: frameRate)
            do {
                try await capture.start(deliver: deliver)
                self.capture = capture
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await host.close()
        self.host = nil
        throw lastError ?? CaptureError.unavailable("The web page couldn\u{2019}t be captured.")
    }

    public func stop() async {
        await capture?.stop()
        capture = nil
        await host?.close()
        host = nil
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
