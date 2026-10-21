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
    /// Called whenever the window's state may have changed: closing, minimizing, being covered by other windows or a
    /// locked screen, and coming back. `isOrderedIn`: the window is open (shown, whether or not it can be seen);
    /// `canBeSeen`: some of it is actually visible.
    var onVisibilityChange: (@MainActor (_ isOrderedIn: Bool, _ canBeSeen: Bool) -> Void)?

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
        var onVisibilityChange: (@MainActor (Bool, Bool) -> Void)?
        var reducesMotion = false {
            didSet { applyAnimationBehavior() }
        }
        private var closeObserver: NSObjectProtocol?
        private var stateObservers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            for observer in stateObservers { NotificationCenter.default.removeObserver(observer) }
            closeObserver = nil
            stateObservers = []
            guard let window else { return }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onWillClose?()
                    self?.onVisibilityChange?(false, false)
                }
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didDeminiaturizeNotification] {
                stateObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportState() }
                })
            }
            reportState()
            window.minSize = WindowConfigurator.minimumSize
            window.backgroundColor = NSColor(Color(hex: STPalette.background))
            window.appearance = NSAppearance(named: .darkAqua)
            applyAnimationBehavior()
            window.setFrameUsingName(WindowConfigurator.frameAutosaveName)
            window.setFrameAutosaveName(WindowConfigurator.frameAutosaveName)
        }

        private func reportState() {
            guard let window else { return }
            onVisibilityChange?(window.isVisible, WindowConfigurator.isVisible(window))
        }

        private func applyAnimationBehavior() {
            window?.animationBehavior = WindowConfigurator.animationBehavior(reducesMotion: reducesMotion)
        }
    }
}
