import AppKit
import Foundation
import STDesign
@testable import STPlatform
import SwiftUI
import Testing
@testable import sTools

/// Stands in for Sparkle: records what it's asked and answers checks when the test says, so no test starts Sparkle,
/// reaches the network or shows one of its windows.
@MainActor
final class FakeUpdater: AppUpdating {
    var unavailableReason: String?
    var lastCheckDate: Date?
    private(set) var applied: [UpdateSettings] = []
    private(set) var checks = 0
    private(set) var shownUpdates = 0
    private var pending: (@MainActor (UpdateCheckResult) -> Void)?

    init(unavailableReason: String? = nil, lastCheckDate: Date? = nil) {
        self.unavailableReason = unavailableReason
        self.lastCheckDate = lastCheckDate
    }

    func apply(_ settings: UpdateSettings) { applied.append(settings) }

    func checkForUpdateInformation(completion: @escaping @MainActor (UpdateCheckResult) -> Void) {
        checks += 1
        pending = completion
    }

    func showUpdate() { shownUpdates += 1 }

    /// Ends the check under way, as Sparkle would.
    func finish(_ result: UpdateCheckResult, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        lastCheckDate = date
        let completion = pending
        pending = nil
        completion?(result)
    }
}

/// Records the notices a check from the app menu would show, instead of an alert.
@MainActor
final class FakeNotices: UpdateNoticePresenting {
    private(set) var shown: [(title: String, message: String)] = []
    func present(title: String, message: String) { shown.append((title, message)) }
}

/// An `AppModel` with `updater`, a temporary settings folder and the harness's fakes.
@MainActor
final class UpdatesHarness {
    let model: AppModel
    let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-updates-\(UUID().uuidString)")
    let store: SettingsStore

    init(updater: (any AppUpdating)?, saved: UpdateSettings? = nil) {
        store = SettingsStore(directory: directory, debounce: .milliseconds(10))
        store.save(AppState(prologueCompleted: true))
        if let saved { store.save(saved) }
        let services = ToolServices(
            settings: store, displays: DisplayDirectory(screenProvider: { [harnessDisplay] }),
            minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])),
            permissions: PermissionCenter(prober: FakeProber(), openURL: { _ in }))
        model = AppModel(services: services, theme: STTheme(), sound: .silent, controllers: [:], updater: updater,
                         hotkeyRegistrar: FakeHotkeyRegistrar(), hotkeyHUD: FakeHotkeyHUD(), loginItem: FakeLoginItem())
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The repository's root, found from this file's place in it.
let repositoryRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("Version text")
struct AppVersionTests {
    @Test func namesTheVersionAndTheBuild() {
        #expect(AppVersion(short: "0.1.0", build: "68").text == "Version 0.1.0 (build 68)")
    }

    @Test func leavesOutAMissingBuild() {
        #expect(AppVersion(short: "0.1.0", build: nil).text == "Version 0.1.0")
        #expect(AppVersion(short: "0.1.0", build: "").text == "Version 0.1.0")
    }

    @Test func aBuildWithoutAVersionIsADevelopmentBuild() {
        #expect(AppVersion(short: nil, build: nil).text == "Development build")
        #expect(AppVersion(short: "", build: "3").text == "Development build")
    }

    @Test func readsTheBundlesInfoPlist() throws {
        let app = try makeBundle(name: "Versioned.app", info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let bundle = try #require(Bundle(url: app))
        #expect(AppVersion(bundle: bundle).text == "Version 1.2.3 (build 45)")
    }

    @MainActor @Test func theAboutWindowShowsTheVersionTheBuildAndTheNotices() throws {
        let options = AboutPanel.options(version: AppVersion(short: "0.1.0", build: "68"))
        #expect(options[.applicationVersion] as? String == "0.1.0")
        #expect(options[.version] as? String == "build 68")
        let credits = try #require(options[.credits] as? NSAttributedString).string
        #expect(credits.contains("Sparkle") && credits.contains("MIT License"))
        #expect(credits.contains("DM Serif Display") && credits.contains("SIL Open Font License"))
    }
}

@MainActor
@Suite("Updates")
struct UpdatesTests {
    @Test func installingIsOffAndCheckingOnByDefault() throws {
        #expect(UpdateSettings.defaultValue.checksAutomatically)
        #expect(!UpdateSettings.defaultValue.installsAutomatically)
        let decoded = try JSONDecoder().decode(UpdateSettings.self, from: Data("{}".utf8))
        #expect(decoded.checksAutomatically && !decoded.installsAutomatically)
    }

    @Test func launchHandsTheSavedSettingsToTheUpdater() {
        let updater = FakeUpdater()
        _ = UpdatesHarness(updater: updater, saved: UpdateSettings(checksAutomatically: false, installsAutomatically: true))
        #expect(updater.applied.last == UpdateSettings(checksAutomatically: false, installsAutomatically: true))
    }

    @Test func eachSwitchIsSavedAndHandedToTheUpdater() async {
        let updater = FakeUpdater()
        let harness = UpdatesHarness(updater: updater)
        harness.model.updatesBinding(\.installsAutomatically).wrappedValue = true
        #expect(updater.applied.last?.installsAutomatically == true)
        harness.model.updatesBinding(\.checksAutomatically).wrappedValue = false
        #expect(updater.applied.last == UpdateSettings(checksAutomatically: false, installsAutomatically: true))
        await harness.model.settings.flush()
        #expect(SettingsStore(directory: harness.directory).load(UpdateSettings.self)
                == UpdateSettings(checksAutomatically: false, installsAutomatically: true))
        #expect(harness.model.updatesBinding(\.installsAutomatically).wrappedValue)
    }

    @Test func checkNowShowsCheckingThenThatSToolsIsUpToDate() {
        let updater = FakeUpdater()
        let notices = FakeNotices()
        let center = UpdateCenter(updater: updater, version: AppVersion(short: "0.1.0", build: "68"), notices: notices)
        #expect(center.statusText == nil)
        center.checkNow()
        #expect(center.phase == .checking)
        #expect(center.statusText == "Checking\u{2026}")
        #expect(!center.canCheck, "one check at a time")
        updater.finish(.upToDate)
        #expect(center.phase == .finished(.upToDate))
        #expect(center.statusText == "sTools is up to date (0.1.0).")
        #expect(center.canCheck)
        #expect(notices.shown.isEmpty, "Settings shows the outcome itself")
        #expect(updater.shownUpdates == 0)
    }

    @Test func anUnreachableFeedGetsACalmLineAndNoAlert() {
        let updater = FakeUpdater()
        let notices = FakeNotices()
        let center = UpdateCenter(updater: updater, version: AppVersion(short: "0.1.0", build: "68"), notices: notices)
        center.checkNow()
        updater.finish(.unreachable)
        #expect(center.statusText == "The update server can\u{2019}t be reached right now. Try again later.")
        #expect(notices.shown.isEmpty)
        #expect(updater.shownUpdates == 0)
    }

    @Test func aFoundUpdateOpensSparklesWindowFromEitherPlace() {
        for origin in [UpdateCenter.Origin.settings, .menu] {
            let updater = FakeUpdater()
            let notices = FakeNotices()
            let center = UpdateCenter(updater: updater, version: AppVersion(short: "0.1.0", build: "68"), notices: notices)
            center.checkNow(from: origin)
            updater.finish(.available(version: "0.2.0"))
            #expect(updater.shownUpdates == 1)
            #expect(center.statusText == "Version 0.2.0 is available.")
            #expect(notices.shown.isEmpty, "Sparkle's window says it")
        }
    }

    @Test func aCheckFromTheMenuEndsWithANotice() {
        let updater = FakeUpdater()
        let notices = FakeNotices()
        let center = UpdateCenter(updater: updater, version: AppVersion(short: "0.1.0", build: "68"), notices: notices)
        center.checkNow(from: .menu)
        updater.finish(.unreachable)
        #expect(notices.shown.map(\.title) == ["Couldn\u{2019}t check for updates"])
        #expect(notices.shown.first?.message == "The update server can\u{2019}t be reached right now. Try again later.")
        center.checkNow(from: .menu)
        updater.finish(.upToDate)
        #expect(notices.shown.last?.title == "You\u{2019}re up to date")
    }

    @Test func aBuildThatCantUpdateSaysWhyAndNeverChecks() {
        let notices = FakeNotices()
        let none = UpdateCenter(updater: nil, version: AppVersion(short: nil, build: nil), notices: notices)
        #expect(none.unavailableReason == "Updates work in the packaged app only.")
        #expect(!none.canCheck)
        none.checkNow()
        #expect(none.phase == .idle)
        none.checkNow(from: .menu)
        #expect(notices.shown.map(\.message) == ["Updates work in the packaged app only."])

        let keyless = FakeUpdater(unavailableReason: "This build has no update key, so it can\u{2019}t check for updates.")
        let center = UpdateCenter(updater: keyless, notices: FakeNotices())
        center.checkNow()
        #expect(keyless.checks == 0)
        #expect(center.unavailableReason == keyless.unavailableReason)
    }

    @Test func theLastCheckIsShownOrSaidNotToHaveHappened() {
        #expect(UpdateCenter.lastCheckText(nil) == "Not checked yet.")
        let text = UpdateCenter.lastCheckText(Date(timeIntervalSince1970: 1_800_000_000),
                                              locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.hasPrefix("Last checked Jan 15, 2027"))
        #expect(text.hasSuffix("8:00\u{202F}AM.") || text.hasSuffix("8:00 AM."))

        let updater = FakeUpdater()
        let center = UpdateCenter(updater: updater, notices: FakeNotices())
        #expect(center.lastCheckText == "Not checked yet.")
        center.checkNow()
        updater.finish(.upToDate)
        #expect(center.lastCheckText.hasPrefix("Last checked "))
    }

    @Test func sparklesOutcomesMapToWhatTheCheckFound() {
        let noUpdate = NSError(domain: "SUSparkleErrorDomain", code: AppUpdater.noUpdateErrorCode)
        #expect(AppUpdater.result(foundVersion: nil, error: noUpdate) == .upToDate)
        #expect(AppUpdater.result(foundVersion: "0.2.0", error: nil) == .available(version: "0.2.0"))
        #expect(AppUpdater.result(foundVersion: nil, error: nil) == .upToDate)
        #expect(AppUpdater.result(foundVersion: nil, error: NSError(domain: "SUSparkleErrorDomain", code: 2001)) == .unreachable)
        #expect(AppUpdater.result(foundVersion: nil, error: URLError(.notConnectedToInternet)) == .unreachable)
        #expect(AppUpdater.result(foundVersion: nil, error: NSError(domain: NSURLErrorDomain, code: 1001)) == .unreachable)
    }

    @Test func onlyAPackagedAppWithTheFeedAndTheKeyCanUpdate() throws {
        let folder = try makeBundle(name: "Plain.bundle", info: ["SUFeedURL": "https://example.com/a.xml", "SUPublicEDKey": "AAAA"])
        let keyless = try makeBundle(name: "Keyless.app", info: ["SUFeedURL": "https://example.com/a.xml"])
        let ready = try makeBundle(name: "Ready.app", info: ["SUFeedURL": "https://example.com/a.xml", "SUPublicEDKey": "AAAA"])
        defer {
            for url in [folder, keyless, ready] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        #expect(AppUpdater.unavailableReason(for: try #require(Bundle(url: folder))) == "Updates work in the packaged app only.")
        #expect(AppUpdater.unavailableReason(for: try #require(Bundle(url: keyless)))
                == "This build has no update key, so it can\u{2019}t check for updates.")
        #expect(AppUpdater.unavailableReason(for: try #require(Bundle(url: ready))) == nil)
        #expect(AppUpdater.unavailableReason(for: Bundle(for: FakeUpdater.self)) != nil, "a test bundle never updates")
    }

    @Test func theUpdatesSectionRendersEachOutcome() {
        for result in [UpdateCheckResult.upToDate, .unreachable, .available(version: "0.2.0")] {
            let updater = FakeUpdater()
            let harness = UpdatesHarness(updater: updater)
            harness.model.navigate(to: .settings)
            harness.model.updateCenter.checkNow()
            updater.finish(result)
            let rep = renderBitmap(PageArea(model: harness.model).environment(\.stTheme, harness.model.theme),
                                   size: CGSize(width: 520, height: 900))
            #expect(distinctColors(in: rep) > 5)
        }
    }
}

/// Makes `<temporary folder>/<random>/<name>` with `Contents/Info.plist` holding `info`.
func makeBundle(name: String, info: [String: String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "sTools-bundle-\(UUID().uuidString)").appending(path: name)
    let contents = url.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist: [String: String] = ["CFBundleIdentifier": "com.example.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
    plist.merge(info) { $1 }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appending(path: "Info.plist"))
    return url
}
