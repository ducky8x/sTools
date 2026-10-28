import Foundation
import OSLog
import Sparkle
import STPlatform

/// What a check someone asked for found.
enum UpdateCheckResult: Equatable, Sendable {
    /// This is the newest version.
    case upToDate
    /// A newer version, by the name people see (its CFBundleShortVersionString).
    case available(version: String)
    /// The update feed couldn't be reached or read (no network, the server is down, the feed isn't published yet).
    case unreachable
    /// A check, or an update's window, is already under way.
    case busy
}

/// The updater as Settings ▸ Updates and the app menu use it (spec 6.3). `AppUpdater` is the real one, built on
/// Sparkle; tests use a fake, so no test starts Sparkle, reaches the network or shows one of its windows.
@MainActor
protocol AppUpdating: AnyObject {
    /// Why this build can't check for updates, or nil when it can.
    var unavailableReason: String? { get }
    /// When sTools last checked, on its own schedule or by hand; nil before the first check.
    var lastCheckDate: Date? { get }
    /// Follows the Settings ▸ Updates switches.
    func apply(_ settings: UpdateSettings)
    /// Checks without showing any window and reports what it found, once.
    func checkForUpdateInformation(completion: @escaping @MainActor (UpdateCheckResult) -> Void)
    /// Hands a found update to Sparkle's own window: what's new, then Install Update, Skip or Remind Me Later.
    func showUpdate()
}

/// Sparkle 2 with its standard windows. It only runs in a packaged app whose Info.plist names the update feed and
/// carries the public update key (`scripts/build-app.sh` writes both); any other build explains why it can't check.
///
/// A check Sparkle makes on its own schedule (daily, `SUScheduledCheckInterval`) that fails says nothing: Sparkle
/// shows a scheduled check's error only after it has shown an update. A check someone asks for goes through
/// `checkForUpdateInformation`, which never shows Sparkle's error alert; the caller words what happened.
@MainActor @Observable
final class AppUpdater: NSObject, AppUpdating, SPUUpdaterDelegate {
    private(set) var unavailableReason: String?
    private(set) var lastCheckDate: Date?

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var pendingCheck: (@MainActor (UpdateCheckResult) -> Void)?
    @ObservationIgnored private var foundVersion: String?
    @ObservationIgnored private let log = STLog.logger("updates")

    /// Sparkle's code for "no newer version in the feed" (`SUNoUpdateError`).
    nonisolated static let noUpdateErrorCode = 1001

    init(bundle: Bundle = .main) {
        unavailableReason = Self.unavailableReason(for: bundle)
        super.init()
        guard unavailableReason == nil else { return }
        // Not SPUStandardUpdaterController: it shows an alert when Sparkle can't start. This only logs.
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                                 userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: self)
        do {
            try updater.start()
            self.updater = updater
            lastCheckDate = updater.lastUpdateCheckDate
        } catch {
            log.error("Updates are off: Sparkle could not start: \(String(describing: error), privacy: .public)")
            unavailableReason = "Updates couldn\u{2019}t start in this copy of sTools."
        }
    }

    /// What Settings ▸ Updates says in the dev build, which has no feed and no key on purpose.
    nonisolated static let devBuildReason = "\(AppVariant.dev.name) never updates itself. To get a newer one, use Install from DMG\u{2026}"

    /// Why a build can't check for updates: it isn't a packaged app, it's the dev build (which never updates itself,
    /// whatever its Info.plist holds), or its Info.plist lacks the feed or the key.
    nonisolated static func unavailableReason(for bundle: Bundle) -> String? {
        guard bundle.bundleURL.pathExtension == "app" else { return "Updates work in the packaged app only." }
        guard AppVariant(bundle: bundle) == .standard else { return devBuildReason }
        let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        guard !feed.trimmingCharacters(in: .whitespaces).isEmpty, !key.trimmingCharacters(in: .whitespaces).isEmpty
        else { return "This build has no update key, so it can\u{2019}t check for updates." }
        return nil
    }

    func apply(_ settings: UpdateSettings) {
        guard let updater, unavailableReason == nil else { return }
        if updater.automaticallyChecksForUpdates != settings.checksAutomatically {
            updater.automaticallyChecksForUpdates = settings.checksAutomatically
        }
        if updater.automaticallyDownloadsUpdates != settings.installsAutomatically {
            updater.automaticallyDownloadsUpdates = settings.installsAutomatically
        }
    }

    func checkForUpdateInformation(completion: @escaping @MainActor (UpdateCheckResult) -> Void) {
        guard let updater, unavailableReason == nil else {
            completion(.unreachable)
            return
        }
        guard pendingCheck == nil, !updater.sessionInProgress else {
            // An update already in its window comes to the front; a check under way just finishes.
            if pendingCheck == nil, updater.canCheckForUpdates { updater.checkForUpdates() }
            completion(.busy)
            return
        }
        pendingCheck = completion
        foundVersion = nil
        updater.checkForUpdateInformation()
    }

    func showUpdate() {
        guard let updater, unavailableReason == nil, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundVersion = item.displayVersionString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheckDate = updater.lastUpdateCheckDate
        if let error = error as NSError?, error.code != Self.noUpdateErrorCode {
            log.notice("Update check ended: \(error.domain, privacy: .public) \(error.code) \(error.localizedDescription, privacy: .public)")
        }
        guard updateCheck == .updateInformation, let completion = pendingCheck else { return }
        pendingCheck = nil
        completion(Self.result(foundVersion: foundVersion, error: error))
    }

    /// How a check that showed no window ended: Sparkle ends one that found an update without an error, and one
    /// that found nothing newer with `SUNoUpdateError`; any other error means the feed couldn't be reached or read.
    nonisolated static func result(foundVersion: String?, error: (any Error)?) -> UpdateCheckResult {
        guard let error = error as NSError? else {
            return foundVersion.map { .available(version: $0) } ?? .upToDate
        }
        return error.domain == SUSparkleErrorDomain && error.code == noUpdateErrorCode ? .upToDate : .unreachable
    }
}
