import Carbon
import Foundation

/// The system side of global hotkeys. `HotkeyCenter` talks only to this protocol, so tests use a fake
/// and never register a real hotkey.
@MainActor
public protocol HotkeyRegistering: AnyObject {
    /// Called when a registered combination is pressed, with the id it was registered under.
    var onPress: (@MainActor (UUID) -> Void)? { get set }

    /// Called when a registered combination's key is released, with the id it was registered under. A registrar
    /// that doesn't report releases keeps the default below.
    var onRelease: (@MainActor (UUID) -> Void)? { get set }

    /// Registers `combo` under `id`. Throws when the system refuses (another app owns the combination).
    func register(_ combo: HotkeyCombo, id: UUID) throws

    /// Removes the registration for `id`. Unknown ids are ignored.
    func unregister(id: UUID)
}

extension HotkeyRegistering {
    /// The default, for a registrar that doesn't report releases: it keeps no callback, so it never calls back and
    /// always reads nil. `HotkeyCenter` reads that as "no releases": it marks no key down, so every press is a new
    /// one and no release is ever sent.
    public var onRelease: (@MainActor (UUID) -> Void)? {
        get { nil }
        set {}
    }
}

/// `RegisterEventHotKey` refused the combination.
public struct HotkeyRegistrationError: Error, Equatable, Sendable {
    /// The Carbon `OSStatus`, for logs.
    public let status: Int32
}

/// The real registrar, built on Carbon `RegisterEventHotKey`. These hotkeys work while any app is
/// focused, need no permission, and the key press is consumed (the focused app never sees it). It reports
/// presses (`kEventHotKeyPressed`) and releases (`kEventHotKeyReleased`).
@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
    public var onPress: (@MainActor (UUID) -> Void)? {
        didSet { box.setCallback(onPress, for: .pressed) }
    }

    public var onRelease: (@MainActor (UUID) -> Void)? {
        didSet { box.setCallback(onRelease, for: .released) }
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
        /// Which way a hotkey's key went.
        enum Edge {
            case pressed
            case released
        }

        private static let signature: OSType = 0x7354_4B59 // 'sTKY'

        private let lock = NSLock()
        private var handler: EventHandlerRef?
        private var hotKeys: [UUID: (ref: EventHotKeyRef, number: UInt32)] = [:]
        private var idsByNumber: [UInt32: UUID] = [:]
        private var nextNumber: UInt32 = 1
        private var callbacks: [Edge: @MainActor (UUID) -> Void] = [:]

        func setCallback(_ callback: (@MainActor (UUID) -> Void)?, for edge: Edge) {
            lock.withLock { callbacks[edge] = callback }
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

        /// Called from the C handler. Looks the hotkey up and hops to the main actor, one task per event, queued in
        /// the order the events came.
        func deliver(_ edge: Edge, number: UInt32) {
            let target: (UUID, @MainActor (UUID) -> Void)? = lock.withLock {
                guard let id = idsByNumber[number], let callback = callbacks[edge] else { return nil }
                return (id, callback)
            }
            guard let (id, callback) = target else { return }
            Task { @MainActor in callback(id) }
        }

        /// Caller holds the lock. One application-wide handler serves every hotkey, pressed and released.
        private func installHandlerIfNeeded() -> OSStatus {
            guard handler == nil else { return noErr }
            let specs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
            }
            var installed: EventHandlerRef?
            let status = InstallEventHandler(GetApplicationEventTarget(), Self.callback, specs.count, specs,
                                             Unmanaged.passUnretained(self).toOpaque(), &installed)
            if status == noErr { handler = installed }
            return status
        }

        private static let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let edge: Edge
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed): edge = .pressed
            case UInt32(kEventHotKeyReleased): edge = .released
            default: return OSStatus(eventNotHandledErr)
            }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == Box.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Box>.fromOpaque(userData).takeUnretainedValue().deliver(edge, number: hotKeyID.id)
            return noErr
        }
    }
}
