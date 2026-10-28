import Foundation
import Testing
@testable import STPlatform

/// The normal build and the dev build (`scripts/build-app.sh --dev`): one app under two names, told apart by one
/// Info.plist key.
@Suite("App variant")
struct AppVariantTests {
    private func makeBundle(info: [String: String]) throws -> (bundle: Bundle, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-variant-\(UUID().uuidString)")
        let contents = folder.appending(path: "Test.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: String] = ["CFBundleIdentifier": "com.example.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
        plist.merge(info) { $1 }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        return (try #require(Bundle(url: folder.appending(path: "Test.app"))), folder)
    }

    @Test func onlyTheDevMarkerMakesTheDevBuild() {
        #expect(AppVariant(marker: "dev") == .dev)
        #expect(AppVariant(marker: nil) == .standard)
        #expect(AppVariant(marker: "") == .standard)
        #expect(AppVariant(marker: "Dev") == .standard, "the marker is exact")
        #expect(AppVariant(marker: "beta") == .standard)
    }

    @Test func theNamesAreTheOnesTheBuildCarries() {
        #expect(AppVariant.standard.name == "sTools")
        #expect(AppVariant.dev.name == "sTools Dev")
        #expect(AppVariant.standard.other == .dev)
        #expect(AppVariant.dev.other == .standard)
    }

    @Test func aBundleSaysWhichBuildItIs() throws {
        let dev = try makeBundle(info: [AppVariant.infoKey: "dev"])
        let normal = try makeBundle(info: [:])
        defer { for item in [dev.folder, normal.folder] { try? FileManager.default.removeItem(at: item) } }
        #expect(AppVariant(bundle: dev.bundle) == .dev)
        #expect(AppVariant(bundle: normal.bundle) == .standard)
        #expect(AppVariant.current == .standard, "the test runner is not the dev build")
    }

    @Test func theInfoKeyIsTheOneTheBuildScriptWrites() throws {
        let script = try String(contentsOf: repositoryRoot.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("plutil -insert \(AppVariant.infoKey) -string dev"))
        let dmgScript = try String(contentsOf: repositoryRoot.appending(path: "scripts/build-dmg.sh"), encoding: .utf8)
        #expect(dmgScript.contains("plutil -extract \(AppVariant.infoKey) raw"))
    }
}

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
