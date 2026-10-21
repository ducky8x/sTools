import AppKit
import Observation

/// Observable permission statuses, requests and System Settings links.
///
/// Nothing runs in the background unless polling began: UIs that show permission status call
/// ``beginPolling(_:interval:)`` when they appear and ``endPolling(_:)`` when they disappear. A poll reads only the
/// permissions it asks for, because most status reads are a round trip to the system's privacy service (several
/// milliseconds each on the main thread, plus that service's own work); Accessibility's read is the cheap one.
@MainActor
@Observable
public final class PermissionCenter {
    public private(set) var statuses: [Permission: PermissionStatus] = [:]

    /// One running poll, returned by ``beginPolling(_:interval:)`` and handed back to ``endPolling(_:)``.
    public struct PollingToken: Hashable, Sendable {
        fileprivate let id: Int
    }

    private struct Poll {
        var token: PollingToken
        var permissions: Set<Permission>
        var interval: Duration
        /// Begun through the older all-permissions ``beginPolling(interval:)``, so ``endPolling()`` can end it.
        var isUntokened: Bool
    }

    /// The system posts this when an app is added to or removed from the Accessibility list, so a revoked grant is
    /// noticed at once, without waiting for the next poll.
    public static let accessibilityChangedNotification = Notification.Name("com.apple.accessibility.api")

    @ObservationIgnored private let prober: PermissionProbing
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let systemNotifications: NotificationCenter
    @ObservationIgnored private var polls: [Poll] = []
    @ObservationIgnored private var nextPollID = 0
    /// What the running timer refreshes, and how often; it restarts when either changes.
    @ObservationIgnored private var timerPlan: (permissions: Set<Permission>, interval: Duration)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?
    @ObservationIgnored private var accessibilityRecheck: Task<Void, Never>?

    /// - Parameter systemNotifications: where the system's Accessibility change notice arrives; tests pass their own.
    public init(
        prober: PermissionProbing = SystemPermissionProber(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        systemNotifications: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        self.prober = prober
        self.openURL = openURL
        self.systemNotifications = systemNotifications
        refresh()
    }

    isolated deinit {
        pollTask?.cancel()
        accessibilityRecheck?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let accessibilityObserver {
            systemNotifications.removeObserver(accessibilityObserver)
        }
    }

    /// Whether any poll is running, for tests.
    public var isPolling: Bool { !polls.isEmpty }

    public func status(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    /// Reads every status from the system. Observers are notified only when something changed.
    public func refresh() {
        refresh(Set(Permission.allCases))
    }

    /// Reads `permissions` from the system and keeps the others as they were. Observers are notified only when
    /// something changed.
    public func refresh(_ permissions: Set<Permission>) {
        var fresh = statuses
        for permission in Permission.allCases where permissions.contains(permission) {
            fresh[permission] = prober.status(for: permission)
        }
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

    /// Starts refreshing every permission every `interval` and whenever the app becomes active, and refreshes once
    /// now. Calls are reference-counted: polling runs until every `beginPolling` has a matching ``endPolling()``.
    public func beginPolling(interval: Duration = .seconds(1)) {
        begin(Set(Permission.allCases), interval: interval, isUntokened: true)
    }

    /// Balances one ``beginPolling(interval:)``. Extra calls do nothing.
    public func endPolling() {
        guard let index = polls.lastIndex(where: \.isUntokened) else { return }
        polls.remove(at: index)
        pollsChanged()
    }

    /// Starts refreshing `permissions` every `interval` and whenever the app becomes active, and refreshes them once
    /// now; Accessibility is also refreshed the moment the system reports a change to its list. Several polls share one
    /// timer, which runs at the shortest interval asked for and reads only the permissions some poll asked for.
    @discardableResult
    public func beginPolling(_ permissions: Set<Permission>, interval: Duration = .seconds(1)) -> PollingToken {
        begin(permissions, interval: interval, isUntokened: false)
    }

    /// Ends the poll `token` stands for. Ending one twice does nothing.
    public func endPolling(_ token: PollingToken) {
        guard let index = polls.firstIndex(where: { $0.token == token }) else { return }
        polls.remove(at: index)
        pollsChanged()
    }

    @discardableResult
    private func begin(_ permissions: Set<Permission>, interval: Duration, isUntokened: Bool) -> PollingToken {
        let token = PollingToken(id: nextPollID)
        nextPollID += 1
        polls.append(Poll(token: token, permissions: permissions, interval: interval, isUntokened: isUntokened))
        refresh(permissions)
        pollsChanged()
        return token
    }

    /// Brings the timer and the observers in line with the polls now running.
    private func pollsChanged() {
        let permissions = polls.reduce(into: Set<Permission>()) { $0.formUnion($1.permissions) }
        guard let interval = polls.map(\.interval).min(), !permissions.isEmpty else {
            stopPolling()
            return
        }
        if timerPlan?.permissions != permissions || timerPlan?.interval != interval {
            timerPlan = (permissions, interval)
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    // A little slack lets macOS fold this wakeup in with others.
                    try? await Task.sleep(for: interval, tolerance: interval / 10)
                    guard !Task.isCancelled, let self else { return }
                    self.refresh(permissions)
                }
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let permissions = self.timerPlan?.permissions else { return }
                    self.refresh(permissions)
                }
            }
        }
        watchAccessibilityList(permissions.contains(.accessibility))
    }

    private func stopPolling() {
        timerPlan = nil
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        watchAccessibilityList(false)
    }

    /// Follows the system's Accessibility list while a poll includes Accessibility. The list can reach the process a
    /// moment after the notice, so Accessibility is read once more a second later.
    private func watchAccessibilityList(_ watching: Bool) {
        if !watching {
            accessibilityRecheck?.cancel()
            accessibilityRecheck = nil
            if let accessibilityObserver { systemNotifications.removeObserver(accessibilityObserver) }
            accessibilityObserver = nil
            return
        }
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = systemNotifications.addObserver(
            forName: Self.accessibilityChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh([.accessibility])
                self.accessibilityRecheck?.cancel()
                self.accessibilityRecheck = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.refresh([.accessibility])
                }
            }
        }
    }
}
