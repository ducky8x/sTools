import Foundation
import Sparkle
import STPlatform

/// Sparkle 2 (spec 6.3), driven by Settings ▸ Updates. It only runs inside a packaged app that carries the
/// update key; a build without one (made before `scripts/make-update-key.sh` was run, or `swift run`) explains
/// that instead of failing.
@MainActor
final class AppUpdater {
    /// Why updates can't run in this build, or nil when they can.
    let unavailableReason: String?

    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if bundle.bundleURL.pathExtension != "app" {
            unavailableReason = "Updates work in the packaged app only."
            controller = nil
        } else if key.isEmpty {
            unavailableReason = "This build has no update key, so it can\u{2019}t check for updates."
            controller = nil
        } else {
            unavailableReason = nil
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
    }

    var isAvailable: Bool { controller != nil }

    /// Follows the two Settings ▸ Updates switches.
    func apply(_ settings: UpdateSettings) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = settings.checksAutomatically
        updater.automaticallyDownloadsUpdates = settings.installsAutomatically
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
