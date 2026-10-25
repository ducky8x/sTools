import AppKit
import STDesign
import STPlatform

/// Keeps sTools hotkeys working while sTools itself is in front (spec 6.1):
/// - they pause only while sTools listens for raw keys: a shortcut field recording (`STKeyCapture`), or a text
///   field or text view being edited while sTools is the active app, or in a panel that has the keyboard with sTools
///   in the background, like Screen Recording's question (the Key Rebinder pauses them itself for Test keys and
///   output capture);
/// - a registered hotkey's key that reaches sTools' own window as a key press goes to the center, which fires it.
///
/// Only the real app has one; tests drive `HotkeyCenter` directly.
@MainActor
final class HotkeyKeyWatcher {
    private let center: HotkeyCenter
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(center: HotkeyCenter) {
        self.center = center
    }

    func start() {
        STKeyCapture.onChange = { [weak center] capturing in center?.setPaused(capturing, for: .recordingKey) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
        let names = [NSApplication.didUpdateNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.appChanged(name) }
            })
        }
        appChanged(NSApplication.didUpdateNotification)
    }

    /// True when a hotkey took the key, so the window doesn't type it. Each key goes with the time it moved (the
    /// event's timestamp, system uptime, as macOS stamps hotkey events), so a key reported here and by macOS counts
    /// once and the timer's gestures measure the keys.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            center.handleKeyDown(keyCode: event.keyCode, modifiers: Self.modifiers(of: event.modifierFlags), isRepeat: event.isARepeat,
                                 at: event.timestamp)
        case .keyUp:
            center.handleKeyUp(keyCode: event.keyCode, at: event.timestamp)
        default:
            false
        }
    }

    private func appChanged(_ name: Notification.Name) {
        if name == NSApplication.didResignActiveNotification { center.releaseWindowKeys() }
        let keyWindow = NSApp.keyWindow
        let typing = Self.isTyping(appIsActive: NSApp.isActive, firstResponder: keyWindow?.firstResponder,
                                   keyWindowIsNonactivatingPanel: Self.takesKeysWithoutActivating(keyWindow))
        if typing != center.pauses.contains(.typing) { center.setPaused(typing, for: .typing) }
    }

    /// ⌃ ⌥ ⇧ ⌘ as a hotkey counts them; Caps Lock, fn and the keypad flag are left out, as macOS leaves them out of
    /// a hotkey's match.
    static func modifiers(of flags: NSEvent.ModifierFlags) -> HotkeyCombo.Modifiers {
        var modifiers: HotkeyCombo.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// Someone is typing in sTools: its key window's first responder is an editable text view (a text field's field
    /// editor is one), while sTools is the active app or that window is a panel that has the keyboard without sTools
    /// being active (Screen Recording's question over Minecraft, spec 5.4.4).
    static func isTyping(appIsActive: Bool, firstResponder: NSResponder?, keyWindowIsNonactivatingPanel: Bool = false) -> Bool {
        guard appIsActive || keyWindowIsNonactivatingPanel, let text = firstResponder as? NSTextView else { return false }
        return text.isEditable
    }

    /// Whether `window` is a panel that takes the keyboard without making sTools the active app.
    static func takesKeysWithoutActivating(_ window: NSWindow?) -> Bool {
        window?.styleMask.contains(.nonactivatingPanel) ?? false
    }
}
