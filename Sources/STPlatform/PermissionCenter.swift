import AppKit
import Observation

/// Observable permission statuses, requests and System Settings links.
///
/// Nothing runs in the background unless ``beginPolling(interval:)`` was called: UIs that show
/// permission status call it when they appear and ``endPolling()`` when they disappear.
@MainActor
@Observable
public final class PermissionCenter {
    public private(set) var statuses: [Permission: PermissionStatus] = [:]

    @ObservationIgnored private let prober: PermissionProbing
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var pollers = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    public init(
        prober: PermissionProbing = SystemPermissionProber(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.prober = prober
        self.openURL = openURL
        refresh()
    }

    isolated deinit {
        pollTask?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    public func status(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    /// Reads every status from the system. Observers are notified only when something changed.
    public func refresh() {
        let fresh = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, prober.status(for: $0)) })
        if fresh != statuses { statuses = fresh }
    }

    /// Asks the system for `permission` and records the outcome. When the system can report the
    /// status after the request, that fresher value wins over the request's own result.
    public func request(_ permission: Permission) async {
        let result = await prober.request(permission)
        let current = prober.status(for: permission)
        let resolved = current == .unknown ? result : current
        if statuses[permission] != resolved { statuses[permission] = resolved }
    }

    /// Opens the System Settings pane for `permission`.
    public func openSettings(for permission: Permission) {
        openURL(permission.settingsURL)
    }

    /// Starts refreshing every `interval` and whenever the app becomes active, and refreshes once now.
    /// Calls are reference-counted: polling runs until every `beginPolling` has a matching
    /// ``endPolling()``. While already polling, `interval` is ignored.
    public func beginPolling(interval: Duration = .seconds(1)) {
        pollers += 1
        refresh()
        guard pollers == 1 else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Balances one ``beginPolling(interval:)``. The last one stops the timer and the activation
    /// observer. Extra calls do nothing.
    public func endPolling() {
        guard pollers > 0 else { return }
        pollers -= 1
        guard pollers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
    }
}
