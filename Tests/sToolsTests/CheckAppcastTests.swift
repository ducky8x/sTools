import Foundation
import Testing

/// `scripts/check-appcast.sh`: Sparkle's own reading of an update feed, from a file or an address. Reading a feed
/// needs Sparkle's framework in `.build/artifacts` (a checkout gets it with `swift package resolve`), so those
/// tests skip without it. The address `--live` reads is fetched by a stand-in `curl`: no test reaches the network.
@Suite("Check appcast")
struct CheckAppcastTests {
    static let script = repositoryRoot.appending(path: "scripts/check-appcast.sh")
    static let hasSparkle = FileManager.default.fileExists(
        atPath: repositoryRoot.appending(path: ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework").path)
    static let itemURL = "https://github.com/ducky8x/sTools/releases/download/v0.1.0/sTools-0.1.0-beta-macOS.dmg"

    /// A folder to work in, with a home and a temporary folder of its own, removed afterwards.
    private final class Workspace {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-check-appcast-\(UUID().uuidString)")
        var bin: URL { folder.appending(path: "bin") }
        var log: URL { folder.appending(path: "calls.log") }
        var feed: URL { folder.appending(path: "appcast.xml") }

        init() throws {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder.appending(path: "tmp"), withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        var environment: [String: String] {
            [
                "HOME": folder.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": folder.appending(path: "tmp").path + "/", "FAKE_LOG": log.path, "FAKE_FEED": feed.path,
            ]
        }

        /// A feed with one signed version, made by the script that publishing uses.
        func writeFeedWithOneVersion() async throws {
            let notes = folder.appending(path: "notes.md")
            try "The first beta.\n".write(to: notes, atomically: true, encoding: .utf8)
            let signature = Data(repeating: 7, count: 64).base64EncodedString()
            let made = try await runScript(
                repositoryRoot.appending(path: "scripts/appcast-add-item.sh"),
                [repositoryRoot.appending(path: "packaging/appcast-template.xml").path, "0.1.0", "155", "15.0",
                 CheckAppcastTests.itemURL, "1234", signature, notes.path],
                environment: environment, timeout: .seconds(60))
            try #require(made.status == 0, "\(made.output)")
            try made.output.write(to: feed, atomically: true, encoding: .utf8)
        }

        /// A `curl` that writes down what it was asked for and answers with `feed` instead of going to the network.
        func installFakeCurl() throws {
            try writeExecutable(#"""
            #!/bin/sh
            echo "curl $*" >> "$FAKE_LOG"
            out=""; url=""
            while [ $# -gt 0 ]; do
                case "$1" in
                --output|-o) out="$2"; shift 2 ;;
                --max-time|--retry|--retry-delay|--connect-timeout) shift 2 ;;
                -*) shift ;;
                *) url="$1"; shift ;;
                esac
            done
            cp "$FAKE_FEED" "$out"
            """#, to: bin.appending(path: "curl"))
        }
    }

    @Test(.enabled(if: hasSparkle, "needs Sparkle in .build/artifacts (swift package resolve)"))
    func sparkleReadsAFeedFromAnAddressAndFindsTheExpectedVersion() async throws {
        let work = try Workspace()
        try await work.writeFeedWithOneVersion()
        let result = try await runScript(Self.script, ["--expect", "0.1.0", "--url", work.feed.absoluteString],
                                         environment: work.environment)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("Sparkle read the feed: 1 item(s)"), "\(result.output)")
        #expect(result.output.contains("0.1.0 (build 155), macOS 15.0 or newer, \(Self.itemURL), EdDSA signature"),
                "\(result.output)")
    }

    @Test(.enabled(if: hasSparkle, "needs Sparkle in .build/artifacts (swift package resolve)"))
    func liveReadsTheAddressBuiltIntoSToolsAndFailsWhenTheVersionIsNotInIt() async throws {
        let work = try Workspace()
        try await work.writeFeedWithOneVersion()
        try work.installFakeCurl()
        let result = try await runScript(Self.script, ["--live", "--expect", "9.9.9"], environment: work.environment)
        #expect(result.status != 0, "9.9.9 is not in the feed")
        #expect(result.output.contains("does not list version 9.9.9"), "\(result.output)")
        let calls = (try? String(contentsOf: work.log, encoding: .utf8)) ?? ""
        #expect(calls.contains(UpdatePackagingTests.feedURL), "asked for the address in Info.plist: \(calls)")
    }

    @Test func aFeedThatCannotBeFetchedIsAnErrorBeforeAnythingElseHappens() async throws {
        let work = try Workspace()
        let missing = work.folder.appending(path: "nowhere/appcast.xml").absoluteString
        let result = try await runScript(Self.script, ["--url", missing], environment: work.environment)
        #expect(result.status != 0)
        #expect(result.output.contains("could not fetch the feed"), "\(result.output)")
        #expect(!result.output.contains(work.folder.path), "the temporary folder's path is not printed: \(result.output)")
    }

    @Test func aFileThatIsNotXMLIsRefusedWithoutSparkle() async throws {
        let work = try Workspace()
        try "not a feed".write(to: work.feed, atomically: true, encoding: .utf8)
        let result = try await runScript(Self.script, [work.feed.path], environment: work.environment)
        #expect(result.status != 0)
        #expect(result.output.contains("is not well-formed XML"), "\(result.output)")
    }
}
