import Foundation
import Testing

/// What packaging gives Sparkle (spec 6.3, 8): the Info.plist keys, the entitlement, the public key and the template
/// feed; then, when there is one, the app `scripts/build-app.sh` last built.
@Suite("Update packaging")
struct UpdatePackagingTests {
    /// The feed baked into every build: the `appcast.xml` attached to the release GitHub marks Latest on the
    /// repository that holds the code (spec 6.3).
    static let feedURL = "https://github.com/ducky8x/sTools/releases/latest/download/appcast.xml"
    static let packaging = repositoryRoot.appending(path: "packaging")

    static func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static var publicKey: String {
        get throws {
            try String(contentsOf: packaging.appending(path: "sparkle-public-key.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func infoPlistNamesTheFeedAndChecksDailyWithoutAsking() throws {
        let info = try Self.plist(Self.packaging.appending(path: "Info.plist"))
        #expect(info["SUFeedURL"] as? String == Self.feedURL)
        #expect(info["SUPublicEDKey"] as? String == "__EDKEY__", "build-app.sh fills it in")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
    }

    @Test func theCommittedPublicKeyIsAnEdDSAKey() throws {
        let key = try Self.publicKey
        #expect(Data(base64Encoded: key)?.count == 32)
    }

    @Test func libraryValidationIsOffSoTheAppCanLoadSparkle() throws {
        let entitlements = try Self.plist(Self.packaging.appending(path: "sTools.entitlements"))
        #expect(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true)
        #expect(entitlements["com.apple.security.app-sandbox"] == nil)
    }

    @Test func theFeedTemplateStartsEmptyAndMarksWhereNewVersionsGo() throws {
        let template = Self.packaging.appending(path: "appcast-template.xml")
        let feed = try XMLDocument(contentsOf: template)
        let root = try #require(feed.rootElement())
        #expect(root.name == "rss")
        #expect(root.namespace(forPrefix: "sparkle")?.stringValue == "http://www.andymatuschak.org/xml-namespaces/sparkle")
        #expect(try feed.nodes(forXPath: "/rss/channel").count == 1)
        #expect(try feed.nodes(forXPath: "/rss/channel/item").isEmpty)
        #expect(try String(contentsOf: template, encoding: .utf8).contains("<!-- New versions go right below this line"))
        #expect(!FileManager.default.fileExists(atPath: Self.packaging.appending(path: "releases-repo").path),
                "the separate releases repository's files are gone")
        #expect(!FileManager.default.fileExists(atPath: repositoryRoot.appending(path: "scripts/create-releases-repo.sh").path))
    }

    @Test func publishingAddsASignedItemAtTheTopOfTheFeed() throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "sTools-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let notes = work.appending(path: "notes.md")
        try "The first beta.\n".write(to: notes, atomically: true, encoding: .utf8)
        let template = Self.packaging.appending(path: "appcast-template.xml").path
        let url = "https://github.com/ducky8x/sTools/releases/download/v0.1.0/sTools-0.1.0-beta-macOS.dmg"
        let signature = Data(repeating: 7, count: 64).base64EncodedString()
        let output = try run(repositoryRoot.appending(path: "scripts/appcast-add-item.sh").path,
                             [template, "0.1.0", "155", "15.0", url, "1234", signature, notes.path])
        #expect(output.status == 0)
        let feed = try XMLDocument(xmlString: output.text)
        let items = try feed.nodes(forXPath: "/rss/channel/item")
        try #require(items.count == 1)
        func value(_ path: String) throws -> String? { try items[0].nodes(forXPath: path).first?.stringValue }
        #expect(try value("sparkle:version") == "155")
        #expect(try value("sparkle:shortVersionString") == "0.1.0")
        #expect(try value("sparkle:minimumSystemVersion") == "15.0")
        #expect(try value("description")?.contains("The first beta.") == true)
        #expect(try value("enclosure/@url") == url)
        #expect(try value("enclosure/@length") == "1234")
        #expect(try value("enclosure/@sparkle:edSignature") == signature)

        let older = work.appending(path: "one.xml")
        try output.text.write(to: older, atomically: true, encoding: .utf8)
        let refused = try run(repositoryRoot.appending(path: "scripts/appcast-add-item.sh").path,
                              [older.path, "0.1.1", "150", "15.0", url, "1", signature, notes.path])
        #expect(refused.status != 0, "a build no newer than one in the feed is refused")
    }

    // MARK: The last built app

    static let builtApp = repositoryRoot.appending(path: "build/sTools.app")
    /// Only an app built with Sparkle in it; an older build, or none, skips these.
    static let hasBuiltApp = FileManager.default.fileExists(
        atPath: builtApp.appending(path: "Contents/Frameworks/Sparkle.framework").path)

    @Test(.enabled(if: hasBuiltApp, "needs build/sTools.app from scripts/build-app.sh"))
    func theBuiltAppCarriesTheFeedTheKeyAndTheEntitlement() throws {
        let info = try Self.plist(Self.builtApp.appending(path: "Contents/Info.plist"))
        #expect(info["SUFeedURL"] as? String == Self.feedURL)
        #expect(info["SUPublicEDKey"] as? String == (try Self.publicKey))
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
        let entitlements = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", Self.builtApp.path])
        #expect(entitlements.text.contains("com.apple.security.cs.disable-library-validation"))
    }

    @Test(.enabled(if: hasBuiltApp, "needs build/sTools.app from scripts/build-app.sh"))
    func everyPieceOfSparkleInTheBuiltAppIsSignedByDucky8x() throws {
        let verify = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", Self.builtApp.path])
        #expect(verify.status == 0, "\(verify.text)")
        let framework = Self.builtApp.appending(path: "Contents/Frameworks/Sparkle.framework/Versions/B")
        let pieces = ["", "Autoupdate", "Updater.app", "XPCServices/Downloader.xpc", "XPCServices/Installer.xpc"]
            .map { $0.isEmpty ? framework.deletingLastPathComponent().deletingLastPathComponent() : framework.appending(path: $0) }
        for piece in pieces + [Self.builtApp] {
            let info = try run("/usr/bin/codesign", ["-dvv", piece.path])
            #expect(info.text.split(separator: "\n").contains("Authority=ducky8x"), "\(piece.lastPathComponent)")
            #expect(info.text.contains("(runtime)"), "\(piece.lastPathComponent) runs with Hardened Runtime")
        }
        let rpaths = try run("/usr/bin/otool", ["-l", Self.builtApp.appending(path: "Contents/MacOS/sTools").path])
        #expect(rpaths.text.contains("path @executable_path/../Frameworks "))
        #expect(!rpaths.text.contains("/.build/"), "no rpath into the build folder")
    }
}

/// Runs `tool` and returns its exit status and everything it printed.
func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, text: String) {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
