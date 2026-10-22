import Foundation
import Testing
@testable import STPlatform

private struct FakeLogReader: LogLineReading {
    var lines: [String] = []
    var failure: (any Error)?
    let recorder = Recorder()

    final class Recorder: @unchecked Sendable {
        var since: Date?
        var limit: Int?
    }

    func recentLines(since: Date, limit: Int) throws -> [String] {
        recorder.since = since
        recorder.limit = limit
        if let failure { throw failure }
        return lines
    }
}

private struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

@MainActor
private final class FakeClipboard: ClipboardWriting {
    var copied: [String] = []
    func copy(_ text: String) { copied.append(text) }
}

private let system = DiagnosticsSystemInfo(
    appVersion: "1.2.3", appBuild: "45", macOSVersion: "15.1.0", architecture: "arm64", localeIdentifier: "en_US")
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let home = "/Users/tester"

private let display = DisplayInfo(
    id: 1, name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
    bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), backingScale: 2,
    pixelSize: CGSize(width: 5120, height: 2880), isMain: true)

private func makeReport(
    displays: [DisplayInfo] = [display],
    permissions: [Permission: PermissionStatus] = [.accessibility: .granted, .camera: .denied],
    karabiner: String = "Karabiner-Elements 16.3.0, running",
    ninjabrain: String = "Ninjabrain Bot reachable on port 52533",
    minecraft: String = "1 instance, 1.16.1",
    enabledTools: [String] = ["crosshair", "backdrop"],
    settingsFiles: [SettingsFileInfo] = [SettingsFileInfo(name: "general.json", bytes: 120)],
    reader: FakeLogReader = FakeLogReader(),
    homeDirectory: String = home
) -> DiagnosticsReport {
    DiagnosticsReport(
        system: system, displays: displays, permissions: permissions, karabiner: karabiner,
        ninjabrain: ninjabrain, minecraft: minecraft, enabledTools: enabledTools,
        settingsFiles: settingsFiles, logReader: reader, now: now, homeDirectory: homeDirectory)
}

@Suite struct DiagnosticsReportTests {
    @Test func reportListsEverySection() {
        let text = makeReport(reader: FakeLogReader(lines: ["12:00:00 [error] Crosshair: oops"])).render()
        #expect(text.contains("sTools 1.2.3 (45)"))
        #expect(text.contains("macOS: 15.1.0"))
        #expect(text.contains("Architecture: arm64"))
        #expect(text.contains("Locale: en_US"))
        #expect(text.contains("Studio Display, 5120 x 2880 px, 2x, main"))
        #expect(text.contains("Accessibility: granted"))
        #expect(text.contains("Camera: denied"))
        #expect(text.contains("Microphone: not reported"))
        #expect(text.contains("Karabiner-Elements: Karabiner-Elements 16.3.0, running"))
        #expect(text.contains("Ninjabrain Bot: Ninjabrain Bot reachable on port 52533"))
        #expect(text.contains("Minecraft: 1 instance, 1.16.1"))
        #expect(text.contains("Enabled tools: crosshair, backdrop"))
        #expect(text.contains("general.json (120 bytes)"))
        #expect(text.contains("12:00:00 [error] Crosshair: oops"))
    }

    /// A settings file's size agrees with its count, one byte included.
    @Test func aOneByteFileReadsInTheSingular() {
        let text = makeReport(settingsFiles: [SettingsFileInfo(name: "tiny.json", bytes: 1), SettingsFileInfo(name: "empty.json", bytes: 0)])
            .render()
        #expect(text.contains("tiny.json (1 byte)"))
        #expect(text.contains("empty.json (0 bytes)"))
    }

    @Test func emptyInputsReadAsNone() {
        let text = makeReport(displays: [], enabledTools: [], settingsFiles: []).render()
        #expect(text.contains("Displays: none"))
        #expect(text.contains("Enabled tools: none"))
        #expect(text.contains("Settings files: none"))
        #expect(text.contains("none in the last 15 minutes"))
    }

    @Test func requestsTheLastFifteenMinutesAndTwoHundredLines() {
        let reader = FakeLogReader()
        _ = makeReport(reader: reader)
        #expect(reader.recorder.since == now.addingTimeInterval(-15 * 60))
        #expect(reader.recorder.limit == 200)
    }

    @Test func neverKeepsMoreThanTwoHundredLogLines() {
        let lines = (1...250).map { "line \($0)" }
        let text = makeReport(reader: FakeLogReader(lines: lines)).render()
        #expect(!text.contains("line 50\n"))
        #expect(text.contains("line 51\n"))
        #expect(text.contains("line 250"))
    }

    @Test func aFailingLogReaderIsReportedNotFatal() {
        let text = makeReport(reader: FakeLogReader(failure: Boom())).render()
        #expect(text.contains("Logs unavailable: boom"))
    }

    @Test func homeDirectoryIsRedactedEverywhere() {
        let text = makeReport(
            karabiner: "config at /Users/tester/.config/karabiner/karabiner.json",
            settingsFiles: [SettingsFileInfo(name: "/Users/tester/x.json", bytes: 1)],
            reader: FakeLogReader(lines: ["opened /Users/tester/Library/Application Support/sTools/general.json"])
        ).render()
        #expect(!text.contains("tester"))
        #expect(text.contains("~/.config/karabiner/karabiner.json"))
        #expect(text.contains("opened ~/Library/Application Support/sTools/general.json"))
    }

    @Test func otherUsersPathsAreRedactedToo() {
        let text = makeReport(minecraft: "game dir /Users/someone-else/games/mc and /Users/x_y.z/a").render()
        #expect(!text.contains("someone-else"))
        #expect(!text.contains("x_y.z"))
        #expect(text.contains("game dir ~/games/mc and ~/a"))
    }

    @Test func aRootOrEmptyHomeRedactsNothingExtra() {
        for home in ["/", ""] {
            let text = makeReport(karabiner: "config at /etc/karabiner/a.json", homeDirectory: home).render()
            #expect(text.contains("config at /etc/karabiner/a.json"))
        }
    }

    @Test func aHomeOutsideUsersIsRedactedWithoutEatingLongerNames() {
        let text = makeReport(karabiner: "/var/ducky/x and /var/ducky2/y", homeDirectory: "/var/ducky").render()
        #expect(text.contains("~/x and /var/ducky2/y"))
    }

    @Test func multiLineSummariesAreIndented() {
        let text = makeReport(karabiner: "line one\nline two").render()
        #expect(text.contains("Karabiner-Elements: line one\n  line two"))
    }

    @Test func settingsFileListHasNamesAndSizesOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sTools-diag-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "Images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("0123456789".utf8).write(to: directory.appending(path: "b.json"))
        try Data("abc".utf8).write(to: directory.appending(path: "a.json"))
        try Data("xx".utf8).write(to: directory.appending(path: "Images/p.png"))

        let files = SettingsFileInfo.list(in: directory)
        #expect(files == [SettingsFileInfo(name: "a.json", bytes: 3), SettingsFileInfo(name: "b.json", bytes: 10)])
        #expect(SettingsFileInfo.list(in: directory.appending(path: "missing")).isEmpty)
    }

    @MainActor
    @Test func copyPutsTheRenderedTextOnTheClipboard() {
        let clipboard = FakeClipboard()
        let report = makeReport()
        report.copy(to: clipboard)
        #expect(clipboard.copied == [report.render()])
    }

    @Test func systemInfoReadsTheBundle() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appending(path: "Fake-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
        let contents = bundleURL.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let plist: [String: Any] = ["CFBundleShortVersionString": "9.8", "CFBundleVersion": "77"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))

        let info = DiagnosticsSystemInfo.current(bundle: try #require(Bundle(url: bundleURL)))
        #expect(info.appVersion == "9.8")
        #expect(info.appBuild == "77")
        #expect(!info.macOSVersion.isEmpty)
        #expect(!info.architecture.isEmpty)
        #expect(!info.localeIdentifier.isEmpty)

        let bare = DiagnosticsSystemInfo.current(bundle: Bundle(for: BundleToken.self))
        #expect(!bare.appVersion.isEmpty)
    }
}

private final class BundleToken {}
