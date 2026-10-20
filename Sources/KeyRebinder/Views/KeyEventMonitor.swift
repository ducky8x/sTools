import AppKit

/// A key or mouse button going down or up, as it arrived in sTools' own window (after Karabiner).
enum KeyPress: Equatable {
    case down(KarabinerEvent, isRepeat: Bool)
    case up(KarabinerEvent)

    var event: KarabinerEvent {
        switch self {
        case .down(let event, _), .up(let event): event
        }
    }
}

/// Watches key and mouse-button events in sTools' own windows only (spec 5.5.5): a local monitor, so no
/// Input Monitoring permission. The handler returns true to swallow an event.
@MainActor
final class KeyEventMonitor {
    private var token: Any?

    func start(_ handler: @escaping @MainActor (KeyPress, NSEvent) -> Bool) {
        stop()
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            guard let press = Self.press(for: event) else { return event }
            let used = MainActor.assumeIsolated { handler(press, event) }
            // Only typing is swallowed; modifier changes and clicks always go on to the window.
            return used && (event.type == .keyDown || event.type == .keyUp) ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    /// `NX_DEVICE*KEYMASK` bits: which side's modifier is held, so releasing one Shift while the other is
    /// still down reads correctly.
    private nonisolated static let sideMasks: [UInt16: UInt] = [
        56: 0x0002, 60: 0x0004, // left / right shift
        59: 0x0001, 62: 0x2000, // left / right control
        58: 0x0020, 61: 0x0040, // left / right option
        55: 0x0008, 54: 0x0010, // left / right command
    ]
    nonisolated static let capsLockKeyCode: UInt16 = 57
    private nonisolated static let fnKeyCode: UInt16 = 63

    nonisolated static func press(for event: NSEvent) -> KeyPress? {
        switch event.type {
        case .keyDown:
            return KeyTester.event(forVirtualKeyCode: Int(event.keyCode)).map { .down($0, isRepeat: event.isARepeat) }
        case .keyUp:
            return KeyTester.event(forVirtualKeyCode: Int(event.keyCode)).map { .up($0) }
        case .flagsChanged:
            guard let key = KeyTester.event(forVirtualKeyCode: Int(event.keyCode)) else { return nil }
            if let mask = sideMasks[event.keyCode] {
                return event.modifierFlags.rawValue & mask != 0 ? .down(key, isRepeat: false) : .up(key)
            }
            if event.keyCode == fnKeyCode {
                return event.modifierFlags.contains(.function) ? .down(key, isRepeat: false) : .up(key)
            }
            // Caps Lock reports each press as a toggle, never a release.
            return event.keyCode == capsLockKeyCode ? .down(key, isRepeat: false) : nil
        case .leftMouseDown: return .down(.pointing("button1"), isRepeat: false)
        case .leftMouseUp: return .up(.pointing("button1"))
        case .rightMouseDown: return .down(.pointing("button2"), isRepeat: false)
        case .rightMouseUp: return .up(.pointing("button2"))
        case .otherMouseDown: return .down(KeyTester.event(forButtonNumber: event.buttonNumber), isRepeat: false)
        case .otherMouseUp: return .up(KeyTester.event(forButtonNumber: event.buttonNumber))
        default: return nil
        }
    }
}
