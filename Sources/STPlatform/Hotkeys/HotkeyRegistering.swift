import Carbon
import Foundation

/// The system side of global hotkeys. `HotkeyCenter` talks only to this protocol, so tests use a fake
/// and never register a real hotkey.
@MainActor
public protocol HotkeyRegistering: AnyObject {
    /// Called when a registered combination is pressed, with the id it was registered under.
    var onPress: (@MainActor (UUID) -> Void)? { get set }

    /// Registers `combo` under `id`. Throws when the system refuses (another app owns the combination).
    func register(_ combo: HotkeyCombo, id: UUID) throws

    /// Removes the registration for `id`. Unknown ids are ignored.
    func unregister(id: UUID)
}

/// `RegisterEventHotKey` refused the combination.
public struct HotkeyRegistrationError: Error, Equatable, Sendable {
    /// The Carbon `OSStatus`, for logs.
    public let status: Int32
}

/// The real registrar, built on Carbon `RegisterEventHotKey`. These hotkeys work while any app is
/// focused, need no permission, and the key press is consumed (the focused app never sees it).
@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
    public var onPress: (@MainActor (UUID) -> Void)? {
        didSet { box.setOnPress(onPress) }
    }

    private let box = Box()

    public init() {}

    public func register(_ combo: HotkeyCombo, id: UUID) throws {
        let status = box.register(combo, id: id)
        guard status == noErr else { throw HotkeyRegistrationError(status: status) }
    }

    public func unregister(id: UUID) {
        box.unregister(id: id)
    }

    deinit {
        box.tearDown()
    }

    /// The Carbon-facing state. The event handler is a C function that runs on the main thread but is
    /// not main-actor isolated as far as Swift can tell, so the state sits behind a lock instead.
    private final class Box: @unchecked Sendable {
        private static let signature: OSType = 0x7354_4B59 // 'sTKY'

        private let lock = NSLock()
        private var handler: EventHandlerRef?
        private var hotKeys: [UUID: (ref: EventHotKeyRef, number: UInt32)] = [:]
        private var idsByNumber: [UInt32: UUID] = [:]
        private var nextNumber: UInt32 = 1
        private var onPress: (@MainActor (UUID) -> Void)?

        func setOnPress(_ callback: (@MainActor (UUID) -> Void)?) {
            lock.withLock { onPress = callback }
        }

        func register(_ combo: HotkeyCombo, id: UUID) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            if let existing = hotKeys.removeValue(forKey: id) {
                UnregisterEventHotKey(existing.ref)
                idsByNumber[existing.number] = nil
            }
            let installed = installHandlerIfNeeded()
            guard installed == noErr else { return installed }

            let number = nextNumber
            nextNumber &+= 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.modifiers.rawValue,
                                             EventHotKeyID(signature: Self.signature, id: number),
                                             GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { return status == noErr ? OSStatus(eventNotHandledErr) : status }
            hotKeys[id] = (ref, number)
            idsByNumber[number] = id
            return noErr
        }

        func unregister(id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            guard let existing = hotKeys.removeValue(forKey: id) else { return }
            UnregisterEventHotKey(existing.ref)
            idsByNumber[existing.number] = nil
        }

        func tearDown() {
            lock.lock()
            defer { lock.unlock() }
            for entry in hotKeys.values { UnregisterEventHotKey(entry.ref) }
            hotKeys.removeAll()
            idsByNumber.removeAll()
            if let handler { RemoveEventHandler(handler) }
            handler = nil
        }

        /// Called from the C handler. Looks the press up and hops to the main actor.
        func pressed(number: UInt32) {
            let target: (UUID, @MainActor (UUID) -> Void)? = lock.withLock {
                guard let id = idsByNumber[number], let onPress else { return nil }
                return (id, onPress)
            }
            guard let (id, callback) = target else { return }
            Task { @MainActor in callback(id) }
        }

        /// Caller holds the lock. One application-wide handler serves every hotkey.
        private func installHandlerIfNeeded() -> OSStatus {
            guard handler == nil else { return noErr }
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            var installed: EventHandlerRef?
            let status = InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &spec,
                                             Unmanaged.passUnretained(self).toOpaque(), &installed)
            if status == noErr { handler = installed }
            return status
        }

        private static let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == Box.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Box>.fromOpaque(userData).takeUnretainedValue().pressed(number: hotKeyID.id)
            return noErr
        }
    }
}
