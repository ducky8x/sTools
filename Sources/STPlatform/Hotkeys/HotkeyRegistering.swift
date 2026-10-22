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

    /// While `onPress` or `onRelease` runs: when the key went down or came up, in seconds of system uptime (the clock
    /// of `ProcessInfo.systemUptime` and `NSEvent.timestamp`), as the system stamped the key event. Nil when the
    /// registrar can't tell, the default below.
    var eventTime: TimeInterval? { get }

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

    /// The default, for a registrar whose events carry no time: `HotkeyCenter` takes each one as happening when it
    /// handles it.
    public var eventTime: TimeInterval? { nil }
}

/// `RegisterEventHotKey` refused the combination.
public struct HotkeyRegistrationError: Error, Equatable, Sendable {
    /// The Carbon `OSStatus`, for logs.
    public let status: Int32
}

/// The real registrar, built on Carbon `RegisterEventHotKey`. These hotkeys work while any app is
/// focused, need no permission, and the key press is consumed (the focused app never sees it). It reports
/// presses (`kEventHotKeyPressed`) and releases (`kEventHotKeyReleased`), each with the time macOS stamped on it
/// (`GetEventTime`), and hands each one over before its Carbon handler returns, so they reach `HotkeyCenter` in the
/// order macOS sent them, among the key events of sTools' own window.
@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
    /// Which way a hotkey's key went.
    enum Edge: Sendable {
        case pressed
        case released
    }

    public var onPress: (@MainActor (UUID) -> Void)?
    public var onRelease: (@MainActor (UUID) -> Void)?
    public private(set) var eventTime: TimeInterval?

    private let box = Box()

    public init() {
        box.setSink { [weak self] edge, id, time in self?.deliver(edge, id: id, at: time) }
    }

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

    /// One event from the Carbon handler: `eventTime` reads its time while the callback runs.
    func deliver(_ edge: Edge, id: UUID, at time: TimeInterval) {
        let outer = eventTime
        eventTime = time
        defer { eventTime = outer }
        switch edge {
        case .pressed: onPress?(id)
        case .released: onRelease?(id)
        }
    }

    /// Runs `body` before returning when called on the main thread, where Carbon calls the application's event
    /// handlers; from any other thread, on the main actor as soon as it can.
    nonisolated static func runOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    /// The Carbon-facing state. The event handler is a C function that runs on the main thread but is
    /// not main-actor isolated as far as Swift can tell, so the state sits behind a lock instead.
    private final class Box: @unchecked Sendable {
        typealias Sink = @MainActor @Sendable (Edge, UUID, TimeInterval) -> Void

        private static let signature: OSType = 0x7354_4B59 // 'sTKY'

        private let lock = NSLock()
        private var handler: EventHandlerRef?
        private var hotKeys: [UUID: (ref: EventHotKeyRef, number: UInt32)] = [:]
        private var idsByNumber: [UInt32: UUID] = [:]
        private var nextNumber: UInt32 = 1
        /// Where each event goes: the registrar, on the main actor.
        private var sink: Sink?

        func setSink(_ sink: @escaping Sink) {
            lock.withLock { self.sink = sink }
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

        /// Called from the C handler. Looks the hotkey up and hands the event over on the main thread before the
        /// handler returns, outside the lock, so the callback may register and unregister hotkeys. A task per event
        /// would reach the center only after whatever the main thread already had queued, sTools' window's own key
        /// events among them.
        func deliver(_ edge: Edge, number: UInt32, at time: TimeInterval) {
            let target: (UUID, Sink)? = lock.withLock {
                guard let id = idsByNumber[number], let sink else { return nil }
                return (id, sink)
            }
            guard let (id, sink) = target else { return }
            CarbonHotkeyRegistrar.runOnMain { sink(edge, id, time) }
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
            // When the key moved: seconds since startup on the uptime clock, as `NSEvent.timestamp` is.
            let time = GetEventTime(event)
            Unmanaged<Box>.fromOpaque(userData).takeUnretainedValue().deliver(edge, number: hotKeyID.id, at: time)
            return noErr
        }
    }
}
