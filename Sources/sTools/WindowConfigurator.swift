import AppKit
import STDesign
import SwiftUI

/// Reaches the hosting `NSWindow` to set what SwiftUI scenes cannot: minimum size, background and remembered frame.
struct WindowConfigurator: NSViewRepresentable {
    static let frameAutosaveName = "sTools.main"
    static let minimumSize = NSSize(width: 680, height: 500)

    /// Called as the window starts to close (it can't be stopped by then; see `AppModel.mainWindowWillClose`).
    var onWillClose: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.onWillClose = onWillClose
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        var onWillClose: (@MainActor () -> Void)?
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            guard let window else { return }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onWillClose?() }
            }
            window.minSize = WindowConfigurator.minimumSize
            window.backgroundColor = NSColor(Color(hex: STPalette.background))
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrameUsingName(WindowConfigurator.frameAutosaveName)
            window.setFrameAutosaveName(WindowConfigurator.frameAutosaveName)
        }
    }
}
