import AppKit
import STDesign
import SwiftUI

/// Reaches the hosting `NSWindow` to set what SwiftUI scenes cannot: minimum size, background, remembered frame, and
/// whether AppKit animates the window opening and closing.
struct WindowConfigurator: NSViewRepresentable {
    static let frameAutosaveName = "sTools.main"
    static let minimumSize = NSSize(width: 680, height: 500)

    /// While true the window opens and closes without AppKit's animation (Reduce animations).
    var reducesMotion = false
    /// Called as the window starts to close (it can't be stopped by then; see `AppModel.mainWindowWillClose`).
    var onWillClose: (@MainActor () -> Void)?
    /// Called with whether the window can be seen whenever that changes: closing, minimizing, being covered by
    /// other windows or a locked screen, and coming back.
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    /// Whether any of `window` can be seen: ordered in, and not minimized or wholly covered.
    static func isVisible(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    /// AppKit's own open and close animation, or none while motion is reduced.
    static func animationBehavior(reducesMotion: Bool) -> NSWindow.AnimationBehavior {
        reducesMotion ? .none : .default
    }

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.onWillClose = onWillClose
        view.onVisibilityChange = onVisibilityChange
        view.reducesMotion = reducesMotion
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ConfiguringView)?.reducesMotion = reducesMotion
    }

    private final class ConfiguringView: NSView {
        var onWillClose: (@MainActor () -> Void)?
        var onVisibilityChange: (@MainActor (Bool) -> Void)?
        var reducesMotion = false {
            didSet { applyAnimationBehavior() }
        }
        private var closeObserver: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            closeObserver = nil
            occlusionObserver = nil
            guard let window else { return }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onWillClose?()
                    self?.onVisibilityChange?(false)
                }
            }
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.onVisibilityChange?(WindowConfigurator.isVisible(window))
                }
            }
            onVisibilityChange?(WindowConfigurator.isVisible(window))
            window.minSize = WindowConfigurator.minimumSize
            window.backgroundColor = NSColor(Color(hex: STPalette.background))
            window.appearance = NSAppearance(named: .darkAqua)
            applyAnimationBehavior()
            window.setFrameUsingName(WindowConfigurator.frameAutosaveName)
            window.setFrameAutosaveName(WindowConfigurator.frameAutosaveName)
        }

        private func applyAnimationBehavior() {
            window?.animationBehavior = WindowConfigurator.animationBehavior(reducesMotion: reducesMotion)
        }
    }
}
