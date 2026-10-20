import AppKit
import SwiftUI

/// The window primitive for everything sTools draws over other apps.
///
/// The topmost role is a transparent, click-through, non-activating panel that sits above the
/// menu bar, the Dock and native full-screen apps, on every Space, and stays capturable so
/// recordings can include it.
@MainActor
public final class OverlayPanel: NSPanel {
    public enum Role: Sendable {
        /// Crosshair and NBB overlay: above everything, click-through.
        case topmost
        /// Window Backdrop: a normal-level panel ordered directly below Minecraft's window, that
        /// swallows clicks instead of passing them through or raising anything (spec 5.2.2).
        case backdrop
    }

    public let role: Role

    /// Whether the panel receives mouse events. Off (click-through) by default; placement mode
    /// turns it on. Turning it on never lets the panel become key or activate the app.
    public var isMouseHandlingEnabled: Bool {
        get { !ignoresMouseEvents }
        set { ignoresMouseEvents = !newValue }
    }

    public init(role: Role = .topmost) {
        self.role = role
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        sharingType = .readOnly
        switch role {
        case .topmost:
            ignoresMouseEvents = true
            // .screenSaver (1000) is above the main menu (24), the Dock (20) and pop-up menus (101),
            // and full-screen apps' Spaces admit it because of .fullScreenAuxiliary.
            level = .screenSaver
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        case .backdrop:
            // Mouse events are handled (not ignored) so `mouseDown` below can swallow them; the panel
            // still can never become key or main, so this never takes focus from Minecraft. No
            // `.canJoinAllSpaces`: the backdrop lives on whatever Space it's shown on, same as any
            // normal window — it's re-shown there each time `reconcile()` places it (spec: "lives on
            // Minecraft's Space").
            ignoresMouseEvents = false
            level = .normal
            collectionBehavior = [.ignoresCycle]
        }
    }

    /// The window numbers of every overlay and backdrop panel on screen: what a recording's base layer
    /// includes besides Minecraft (rule R5), and nothing else of sTools.
    public static func visibleWindowNumbers() -> [UInt32] {
        NSApp.windows.compactMap { $0 as? OverlayPanel }.filter(\.isVisible).map { UInt32($0.windowNumber) }
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    /// Backdrop panels never come forward, activate sTools or raise a hidden window on click
    /// (spec 5.2.1): swallow the click by not forwarding it to the responder chain.
    override public func mouseDown(with event: NSEvent) {
        guard role == .backdrop else { return super.mouseDown(with: event) }
        NSApp.preventWindowOrdering()
    }

    /// Borderless windows may still be nudged below the menu bar; overlays must sit exactly where asked.
    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Hosts SwiftUI content over a clear background.
    public func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        // Without this the hosting view resizes the window to its content.
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
    }

    /// Shows the panel at `frame` (AppKit global coordinates) without activating the app.
    public func show(frame: CGRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    /// Shows the panel at `frame` ordered directly below the window numbered `windowNumber`
    /// (spec 5.2.2), without activating the app or bringing the panel itself to front.
    public func showBelow(frame: CGRect, windowNumber: Int) {
        setFrame(frame, display: true)
        order(.below, relativeTo: windowNumber)
    }

    public func hide() {
        orderOut(nil)
    }

    /// Moves/resizes an already-shown panel without reordering it — for smooth placement-mode
    /// dragging, where reasserting front-or-below-window ordering on every drag frame is wasted work.
    public func moveTo(frame: CGRect) {
        setFrame(frame, display: true)
    }
}
