import AppKit
import SwiftUI

/// Any click or key press in the window completes the animation playing on the current step (spec 4.1). The key
/// that does so is used up, so the first Return finishes the typing and the second continues — except Back, Skip
/// step and Skip introduction, which always go through.
struct AnimationCompleter: NSViewRepresentable {
    let animations: PrologueAnimations

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.gate = animations
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.gate = animations
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var gate: PrologueAnimations?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                let swallows = MainActor.assumeIsolated { self?.swallows(event) ?? false }
                return swallows ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Completes the running animation; true when the event should go no further.
        private func swallows(_ event: NSEvent) -> Bool {
            guard event.window === window, let gate, gate.completeAll() else { return false }
            return event.type == .keyDown && !Self.alwaysPassesThrough(event)
        }

        /// Esc, ⌘[ and ⌘].
        static func alwaysPassesThrough(_ event: NSEvent) -> Bool {
            if event.keyCode == 53 { return true }
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            return command && ["[", "]"].contains(event.charactersIgnoringModifiers ?? "")
        }
    }
}
