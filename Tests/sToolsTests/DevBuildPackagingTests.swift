import Foundation
import STDesign
import STPlatform
import Testing

/// What packaging gives the dev build (`scripts/build-app.sh --dev`, `scripts/build-dmg.sh --dev`): its blue icon, the
/// guards that keep the two kinds of app out of each other's DMG, and, when there is one, the dev app last built.
@Suite("Dev build packaging")
struct DevBuildPackagingTests {
    static let packaging = repositoryRoot.appending(path: "packaging")

    private static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: The icon

    @Test func theDevIconIsTheNormalIconInBlue() throws {
        let normal = try Self.text(Self.packaging.appending(path: "AppIcon.icon/Assets/Mark.svg"))
        let dev = try Self.text(Self.packaging.appending(path: "dev/AppIcon.icon/Assets/Mark.svg"))
        #expect(normal.contains("fill=\"\(STPalette.gold)\""), "the normal icon is the app's gold")
        #expect(dev.contains("fill=\"#62A5EB\""), "the dev icon is blue")
        #expect(dev.replacingOccurrences(of: "#62A5EB", with: STPalette.gold) == normal, "only the color differs")
        #expect(try Self.text(Self.packaging.appending(path: "dev/AppIcon.icon/icon.json"))
                == (try Self.text(Self.packaging.appending(path: "AppIcon.icon/icon.json"))), "the same plate")
    }

    @Test func theDevIconHasItsFallbackIcnsToo() throws {
        let dev = try Data(contentsOf: Self.packaging.appending(path: "dev/sTools.icns"))
        let normal = try Data(contentsOf: Self.packaging.appending(path: "sTools.icns"))
        #expect(dev.prefix(4) == Data("icns".utf8))
        #expect(dev != normal)
    }

    // MARK: Info.plist

    @Test func theInfoPlistTemplateIsTheNormalBuildAndTheDevBuildIsMadeFromIt() throws {
        let info = try UpdatePackagingTests.plist(Self.packaging.appending(path: "Info.plist"))
        #expect(info[AppVariant.infoKey] == nil, "the template is the normal build's")
        #expect(info["CFBundleName"] as? String == "sTools")
        #expect(info["CFBundleDisplayName"] as? String == "sTools")
        #expect(info["CFBundleIdentifier"] as? String == "com.ducky8x.sTools", "the dev build keeps this identifier")
        let script = try Self.text(repositoryRoot.appending(path: "scripts/build-app.sh"))
        #expect(script.contains("plutil -replace \"$key\" -string \"sTools Dev\""))
        #expect(script.contains("for key in SUFeedURL SUEnableAutomaticChecks SUScheduledCheckInterval"))
    }

    // MARK: The scripts' guards

    private func makeApp(variant: String?, feed: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-dev-guard-\(UUID().uuidString)")
        let app = folder.appending(path: "build/App.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.ducky8x.sTools", "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1"]
        if let variant { info[AppVariant.infoKey] = variant }
        if feed { info["SUFeedURL"] = "https://example.com/appcast.xml" }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    private func buildDMG(_ arguments: [String], app: URL? = nil) throws -> (status: Int32, text: String) {
        let output = FileManager.default.temporaryDirectory.appending(path: "sTools-dev-guard-out-\(UUID().uuidString)/x.dmg")
        let app = app.map { ["--app", $0.path] } ?? []
        return try run(repositoryRoot.appending(path: "scripts/build-dmg.sh").path, arguments + app + ["--output", output.path])
    }

    @Test func aDevDMGIsNeverABeta() throws {
        let result = try buildDMG(["--dev", "--beta"])
        #expect(result.status != 0)
        #expect(result.text.contains("--dev and --beta can't go together"), "\(result.text)")
    }

    @Test func theDevDMGTakesOnlyADevApp() throws {
        let normalApp = try makeApp(variant: nil)
        defer { try? FileManager.default.removeItem(at: normalApp.deletingLastPathComponent().deletingLastPathComponent()) }
        let result = try buildDMG(["--dev"], app: normalApp)
        #expect(result.status != 0)
        #expect(result.text.contains("is not a dev build"), "\(result.text)")
    }

    @Test func theDevDMGRefusesAnAppThatCouldUpdateItself() throws {
        let app = try makeApp(variant: "dev", feed: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
        let result = try buildDMG(["--dev"], app: app)
        #expect(result.status != 0)
        #expect(result.text.contains("names an update feed"), "\(result.text)")
    }

    @Test func theNormalDMGRefusesTheDevApp() throws {
        let devApp = try makeApp(variant: "dev")
        defer { try? FileManager.default.removeItem(at: devApp.deletingLastPathComponent().deletingLastPathComponent()) }
        let result = try buildDMG([], app: devApp)
        #expect(result.status != 0)
        #expect(result.text.contains("is a dev build; package it with --dev"), "\(result.text)")
    }

    // MARK: The last built dev app

    static let builtApp = repositoryRoot.appending(path: "build/sTools Dev.app")
    static let hasBuiltApp = FileManager.default.fileExists(atPath: builtApp.appending(path: "Contents/Info.plist").path)

    @Test(.enabled(if: hasBuiltApp, "needs build/sTools Dev.app from scripts/build-app.sh --dev"))
    func theBuiltDevAppIsNamedBlueAndNeverUpdates() throws {
        let info = try UpdatePackagingTests.plist(Self.builtApp.appending(path: "Contents/Info.plist"))
        #expect(info[AppVariant.infoKey] as? String == "dev")
        #expect(info["CFBundleName"] as? String == "sTools Dev")
        #expect(info["CFBundleDisplayName"] as? String == "sTools Dev")
        #expect(info["CFBundleIdentifier"] as? String == "com.ducky8x.sTools", "shared with the normal build")
        for key in ["SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUScheduledCheckInterval"] {
            #expect(info[key] == nil, "\(key) would let it update itself")
        }
        let signature = try run("/usr/bin/codesign", ["-dvv", Self.builtApp.path])
        #expect(signature.text.split(separator: "\n").contains("Authority=ducky8x"))
        #expect(signature.text.contains("Identifier=com.ducky8x.sTools"))
    }
}
