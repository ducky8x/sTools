import ServiceManagement

/// What the system says about the "open at login" registration.
public enum LoginItemState: Sendable, Equatable {
    /// Registered and allowed to run at login.
    case enabled
    /// Not registered.
    case notRegistered
    /// Registered, but the user has not approved it (or switched it off) in System Settings ▸ General ▸ Login Items.
    case requiresApproval
    /// The system cannot find the app's login item (for example, the app runs from an unusual location).
    case notFound

    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .notRegistered
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }

    /// Whether the app is registered, which is what the Settings switch shows.
    /// `requiresApproval` counts as on: the switch stays on and the page explains what is missing.
    public var isEnabled: Bool { self == .enabled || self == .requiresApproval }
}

/// The "Open at login" switch (Settings ▸ General).
@MainActor
public protocol LoginItemControlling: AnyObject {
    var state: LoginItemState { get }
    /// Whether the app is registered to open at login (see `LoginItemState.isEnabled`).
    var isEnabled: Bool { get }
    /// Registers or unregisters the app. Does nothing when already in the requested state.
    func setEnabled(_ enabled: Bool) throws
    /// Opens System Settings ▸ General ▸ Login Items, where the user approves a `requiresApproval` item.
    func openSystemSettings()
}

extension LoginItemControlling {
    public var isEnabled: Bool { state.isEnabled }
}

/// The calls `SystemLoginItem` makes on the system; `SMAppService` is the real conformer.
@MainActor
protocol LoginItemBackend: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
private final class MainAppBackend: LoginItemBackend {
    private let service = SMAppService.mainApp
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

/// `SMAppService.mainApp` behind `LoginItemControlling`.
@MainActor
public final class SystemLoginItem: LoginItemControlling {
    private let backend: any LoginItemBackend

    public init() {
        backend = MainAppBackend()
    }

    init(backend: any LoginItemBackend) {
        self.backend = backend
    }

    public var state: LoginItemState { LoginItemState(backend.status) }

    public func setEnabled(_ enabled: Bool) throws {
        let current = state
        if enabled {
            if !current.isEnabled { try backend.register() }
        } else if current.isEnabled {
            try backend.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// An in-memory `LoginItemControlling` for tests and previews.
@MainActor
public final class FakeLoginItem: LoginItemControlling {
    public var state: LoginItemState
    /// When set, `setEnabled(_:)` throws it and leaves `state` unchanged.
    public var failure: (any Error)?
    public private(set) var openSettingsCount = 0

    public init(state: LoginItemState = .notRegistered) {
        self.state = state
    }

    public func setEnabled(_ enabled: Bool) throws {
        if let failure { throw failure }
        state = enabled ? .enabled : .notRegistered
    }

    public func openSystemSettings() {
        openSettingsCount += 1
    }
}
