import AppKit
import Foundation
import Observation
import STDesign
import STPlatform

/// This copy's version, as its Info.plist states it.
struct AppVersion: Equatable, Sendable {
    /// CFBundleShortVersionString, such as "0.1.0".
    var short: String?
    /// CFBundleVersion, the build number.
    var build: String?

    init(short: String?, build: String?) {
        self.short = short?.isEmpty == false ? short : nil
        self.build = build?.isEmpty == false ? build : nil
    }

    init(bundle: Bundle = .main) {
        self.init(short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// "Version 0.1.0 (build 68)": what Settings ▸ Updates and the About window say.
    var text: String {
        switch (short, build) {
        case let (short?, build?): "Version \(short) (build \(build))"
        case let (short?, nil): "Version \(short)"
        default: "Development build"
        }
    }
}

/// Shows the outcome of a check made from the app menu, where Settings ▸ Updates may not be on screen.
@MainActor
protocol UpdateNoticePresenting: AnyObject {
    func present(title: String, message: String)
}

/// A plain informational alert with one OK button; while motion is reduced it appears without AppKit's animation.
@MainActor
final class AlertUpdateNoticePresenter: UpdateNoticePresenting {
    private let theme: STTheme

    init(theme: STTheme) {
        self.theme = theme
    }

    func present(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.layout()
        alert.window.animationBehavior = WindowConfigurator.animationBehavior(reducesMotion: theme.reduceMotion)
        NSApp.activate()
        alert.runModal()
    }
}

/// Settings ▸ Updates and Check for Updates… (spec 6.3): the version, the last check, and what a check someone
/// asked for found. Sparkle's own scheduled checks run by themselves; when one fails nothing is shown.
@MainActor @Observable
final class UpdateCenter {
    /// Where a check someone asked for stands.
    enum Phase: Equatable, Sendable {
        case idle
        case checking
        case finished(UpdateCheckResult)
    }

    /// Where the person asked for the check: the Updates section shows its own outcome; the app menu's is shown as
    /// a notice, except a found update, which Sparkle's window shows either way.
    enum Origin: Sendable { case settings, menu }

    private(set) var phase: Phase = .idle
    let version: AppVersion
    @ObservationIgnored let updater: (any AppUpdating)?
    @ObservationIgnored let notices: any UpdateNoticePresenting

    init(updater: (any AppUpdating)?, version: AppVersion = AppVersion(), notices: any UpdateNoticePresenting) {
        self.updater = updater
        self.version = version
        self.notices = notices
    }

    /// Why this copy can't check for updates (a test, `swift run`, a build without the update key), or nil.
    var unavailableReason: String? {
        guard let updater else { return "Updates work in the packaged app only." }
        return updater.unavailableReason
    }

    var canCheck: Bool { unavailableReason == nil && phase != .checking }

    /// Hands the Settings ▸ Updates switches to the updater.
    func apply(_ settings: UpdateSettings) {
        updater?.apply(settings)
    }

    /// Checks now, without any window of Sparkle's unless it finds an update.
    func checkNow(from origin: Origin = .settings) {
        guard canCheck, let updater else {
            if origin == .menu, let reason = unavailableReason {
                notices.present(title: "Updates aren\u{2019}t available here", message: reason)
            }
            return
        }
        phase = .checking
        updater.checkForUpdateInformation { [weak self] result in
            guard let self else { return }
            phase = .finished(result)
            if case .available = result {
                updater.showUpdate()
            } else if origin == .menu {
                notices.present(title: Self.noticeTitle(for: result), message: Self.statusText(for: result, version: version))
            }
        }
    }

    /// The line beside Check Now; nil before any check this session.
    var statusText: String? {
        switch phase {
        case .idle: nil
        case .checking: "Checking\u{2026}"
        case .finished(let result): Self.statusText(for: result, version: version)
        }
    }

    static func statusText(for result: UpdateCheckResult, version: AppVersion) -> String {
        switch result {
        case .upToDate:
            "sTools is up to date" + (version.short.map { " (\($0))." } ?? ".")
        case .available(let newer):
            "Version \(newer) is available."
        case .unreachable:
            "The update server can\u{2019}t be reached right now. Try again later."
        case .busy:
            "sTools is already checking. Try again in a moment."
        }
    }

    static func noticeTitle(for result: UpdateCheckResult) -> String {
        switch result {
        case .upToDate: "You\u{2019}re up to date"
        case .available: "An update is available"
        case .unreachable: "Couldn\u{2019}t check for updates"
        case .busy: "Already checking for updates"
        }
    }

    /// "Last checked Oct 21, 2026 at 4:31 AM.", or that sTools hasn't checked yet.
    var lastCheckText: String { Self.lastCheckText(updater?.lastCheckDate) }

    static func lastCheckText(_ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date else { return "Not checked yet." }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return "Last checked \(date.formatted(style))."
    }
}
