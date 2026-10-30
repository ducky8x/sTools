import Foundation
import Testing

/// `scripts/publish-update.sh` (spec 6.3) in a throwaway repository against a fake GitHub (`PublishFixture`): what it
/// refuses, what it builds and writes, and that a real run makes one Latest release at the build's commit without
/// pushing or tagging anything itself. None of it reaches the network, the keychain or the real repository.
@Suite("Publish update")
struct PublishUpdateTests {
    private static let downloadBase = "https://github.com/ducky8x/sTools/releases/download"

    private func feed(_ url: URL) throws -> XMLDocument { try XMLDocument(contentsOf: url) }

    private func count(in document: XMLDocument) throws -> Int {
        try document.nodes(forXPath: "/rss/channel/item").count
    }

    /// The text at an XPath of the document, such as `/rss/channel/item[1]/sparkle:version`.
    private func value(_ path: String, in document: XMLDocument) throws -> String? {
        try document.nodes(forXPath: path).first?.stringValue
    }

    private func createCall(_ world: PublishFixture) throws -> String {
        let line = world.calls.split(separator: "\n").first { $0.hasPrefix("gh release create") }
        return try #require(line).description
    }

    // MARK: A dry run

    @Test func aDryRunBuildsSignsAndWritesTheFeedButCreatesNothing() async throws {
        let world = try await PublishFixture()
        let before = try await world.originRefs()
        let result = try await world.run(["--version", "0.3.0", "--dry-run"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("Dry run"), "\(result.output)")
        #expect(result.output.contains("nothing was created on GitHub"), "\(result.output)")

        #expect(world.calls.contains("build-app release VERSION=0.3.0 BUILD_NUMBER=3"), "built the release app")
        #expect(world.calls.contains("build-dmg"), "built the DMG")
        #expect(world.calls.contains("sign_update --account sTools"), "signed it with the keychain's key")

        let written = try feed(world.published("v0.3.0").appending(path: "appcast.xml"))
        try #require(try count(in: written) == 1, "the first release starts from the template")
        let item = "/rss/channel/item[1]"
        #expect(try value("\(item)/sparkle:shortVersionString", in: written) == "0.3.0")
        #expect(try value("\(item)/sparkle:version", in: written) == "3")
        #expect(try value("\(item)/enclosure/@url", in: written) == "\(Self.downloadBase)/v0.3.0/sTools-0.3.0-macOS.dmg")
        #expect(try value("\(item)/enclosure/@sparkle:edSignature", in: written) == "RkFLRVNJR05BVFVSRQ==")
        #expect(try value("\(item)/enclosure/@length", in: written) == "4096")
        #expect(try world.read(world.published("v0.3.0").appending(path: "release-notes.md")) == "sTools 0.3.0.\n")

        #expect(result.output.contains(#"gh release create v0.3.0 "$HOME/Projects/App Outputs/sTools-0.3.0-macOS.dmg" build/publish/v0.3.0/appcast.xml"#),
                "the command can be pasted into a terminal in the repository: \(result.output)")
        #expect(!result.output.contains("sTools-publish-"), "no path of this machine is printed: \(result.output)")
        #expect(!world.calls.contains("gh release create"), "no release in a dry run")
        #expect(try await world.originRefs() == before, "origin is as it was")
    }

    @Test func theNewVersionGoesOnTopOfTheLatestReleasesFeed() async throws {
        let world = try await PublishFixture()
        try await world.addEarlierRelease()
        let result = try await world.run(["--version", "0.3.0", "--dry-run"])
        #expect(result.status == 0, "\(result.output)")
        #expect(world.calls.contains("gh release download v0.2.0"), "the earlier feed comes from the latest release")

        let written = try feed(world.published("v0.3.0").appending(path: "appcast.xml"))
        try #require(try count(in: written) == 2)
        #expect(try value("/rss/channel/item[1]/sparkle:shortVersionString", in: written) == "0.3.0", "newest first")
        #expect(try value("/rss/channel/item[2]/sparkle:shortVersionString", in: written) == "0.2.0", "the earlier version stays")
        #expect(try value("/rss/channel/item[2]/enclosure/@url", in: written)
                == "\(Self.downloadBase)/v0.2.0/sTools-0.2.0-macOS.dmg")
    }

    // MARK: A real run

    @Test func aRealRunMakesOneLatestReleaseAtTheBuildsCommitAndPushesNothing() async throws {
        let world = try await PublishFixture(visibility: "PUBLIC")
        try await world.addEarlierRelease()
        let before = try await world.originRefs()
        let result = try await world.run(["--version", "0.3.0", "--yes"])
        #expect(result.status == 0, "\(result.output)")

        let create = try createCall(world)
        #expect(create.hasPrefix("gh release create v0.3.0 "), "tagged v<version>: \(create)")
        #expect(create.contains("--repo ducky8x/sTools"))
        #expect(create.contains("--target \(world.headSHA)"), "on the commit the build came from")
        #expect(create.contains("--latest"))
        #expect(!create.contains("--prerelease") && !create.contains("--draft"), "the feed address needs a plain release")
        #expect(create.contains("/sTools-0.3.0-macOS.dmg"), "the DMG is attached")
        #expect(create.contains("/appcast.xml"), "the feed is attached")
        #expect(world.calls.components(separatedBy: "gh release create").count == 2, "one release, one call")

        // What GitHub holds: both assets, the feed being the one the script wrote.
        let assets = try world.read(world.github.appending(path: "assets/v0.3.0"))
        #expect(assets.contains("sTools-0.3.0-macOS.dmg 4096"))
        #expect(assets.contains("appcast.xml "))
        #expect(try world.read(world.github.appending(path: "files/v0.3.0/appcast.xml"))
                == (try world.read(world.published("v0.3.0").appending(path: "appcast.xml"))))
        #expect(try world.read(world.github.appending(path: "latest")) == "v0.3.0\n")

        #expect(world.calls.contains("check-appcast --live --expect 0.3.0"), "the public address was checked afterwards")
        #expect(result.output.contains("Published sTools 0.3.0 (build 3)"), "\(result.output)")
        #expect(!result.output.contains("sTools-publish-"), "no path of this machine is printed: \(result.output)")

        // The script makes no commit, branch or tag, and pushes nothing: gh creates the tag on GitHub.
        #expect(!world.calls.contains("git push"))
        #expect(try await world.originRefs() == before, "origin is as it was")
    }

    @Test func aBetaIsNamedAsOneAndStillMarkedLatest() async throws {
        let world = try await PublishFixture(visibility: "PUBLIC")
        let result = try await world.run(["--version", "0.3.0", "--beta", "--yes"])
        #expect(result.status == 0, "\(result.output)")
        #expect(world.calls.contains("build-dmg --beta"))
        let create = try createCall(world)
        #expect(create.contains("/sTools-0.3.0-beta-macOS.dmg"))
        #expect(create.contains("--latest") && !create.contains("--prerelease"), "a pre-release would break the feed")
        let written = try feed(world.published("v0.3.0").appending(path: "appcast.xml"))
        #expect(try value("/rss/channel/item[1]/enclosure/@url", in: written)
                == "\(Self.downloadBase)/v0.3.0/sTools-0.3.0-beta-macOS.dmg")
    }

    @Test func withoutYesItAsksFirstAndCreatesNothingWithoutAnAnswer() async throws {
        let world = try await PublishFixture()
        let result = try await world.run(["--version", "0.3.0"])
        #expect(result.status != 0)
        #expect(result.output.contains("nothing was published"), "\(result.output)")
        #expect(!world.calls.contains("gh release create"))
    }

    @Test func whileTheRepositoryIsPrivateItSaysNobodyCanReadTheFeedYetAndDoesNotCheckIt() async throws {
        let world = try await PublishFixture(visibility: "PRIVATE")
        let result = try await world.run(["--version", "0.3.0", "--yes"])
        #expect(result.status == 0, "the release itself worked: \(result.output)")
        #expect(result.output.contains("private"), "\(result.output)")
        #expect(result.output.contains("public"), "\(result.output)")
        #expect(!world.calls.contains("check-appcast --live"), "a private repository can't answer an anonymous reader")
        #expect(world.calls.contains("gh release create"))
    }

    @Test func aPublicRepositoryWhoseFeedDoesNotResolveIsAFailure() async throws {
        let world = try await PublishFixture(visibility: "PUBLIC")
        let result = try await world.run(["--version", "0.3.0", "--yes"],
                                         environment: ["FAKE_NO_LIVE_FEED": "1", "STOOLS_PUBLISH_WAIT_SECONDS": "0"])
        #expect(result.status != 0)
        #expect(result.output.contains("does not resolve"), "\(result.output)")
        #expect(world.calls.contains("gh release create"), "the release exists, and the message says so")
    }

    // MARK: What it refuses

    @Test func itRefusesACommitThatIsNotOnOriginMainAndBuildsNothing() async throws {
        let world = try await PublishFixture()
        try await world.commit("Not pushed yet")
        let result = try await world.run(["--version", "0.3.0", "--yes"])
        #expect(result.status != 0)
        #expect(result.output.contains("is not on origin/main"), "\(result.output)")
        #expect(result.output.contains("git push origin main"), "it says to push first: \(result.output)")
        #expect(!world.calls.contains("build-app"))
        #expect(!world.calls.contains("gh release create"))
    }

    @Test func itRefusesUncommittedChanges() async throws {
        let world = try await PublishFixture()
        try world.write("loose\n", "repo/loose.txt")
        let result = try await world.run(["--version", "0.3.0", "--yes"])
        #expect(result.status != 0)
        #expect(result.output.contains("commit or stash"), "\(result.output)")
        #expect(!world.calls.contains("build-app"))
    }

    @Test func itRefusesAnotherGitHubAccount() async throws {
        let world = try await PublishFixture()
        try world.write("someone-else\n", "github/login")
        let result = try await world.run(["--version", "0.3.0", "--yes"])
        #expect(result.status != 0)
        #expect(result.output.contains("someone-else") && result.output.contains("ducky8x"), "\(result.output)")
        #expect(!world.calls.contains("build-app"))
    }

    @Test func itRefusesAVersionThatAlreadyHasARelease() async throws {
        let world = try await PublishFixture()
        try await world.addEarlierRelease()
        let result = try await world.run(["--version", "0.2.0", "--yes"])
        #expect(result.status != 0)
        #expect(result.output.contains("already has a release v0.2.0"), "\(result.output)")
        #expect(!world.calls.contains("build-app"))
    }

    @Test func itRefusesAVersionWhoseTagIsAlreadyOnGitHub() async throws {
        let world = try await PublishFixture()
        try await world.git(["tag", "v0.3.0"])
        try await world.git(["push", "-q", "origin", "v0.3.0"])
        try await world.git(["tag", "-d", "v0.3.0"])
        let result = try await world.run(["--version", "0.3.0", "--yes"])
        #expect(result.status != 0)
        #expect(result.output.contains("tag v0.3.0 already exists"), "\(result.output)")
        #expect(!world.calls.contains("build-app"))
    }

    @Test func itRefusesWhenTheLatestReleaseHasNoFeedToAddTo() async throws {
        let world = try await PublishFixture()
        try world.write("v0.2.0\n", "github/tags")
        try world.write("v0.2.0\n", "github/latest")
        let result = try await world.run(["--version", "0.3.0", "--yes"])
        #expect(result.status != 0)
        #expect(result.output.contains("has no appcast.xml"), "\(result.output)")
        #expect(!world.calls.contains("build-app"))
    }

    @Test func itRefusesAVersionThatIsNotNewerThanTheFeed() async throws {
        let world = try await PublishFixture()
        try await world.addEarlierRelease()
        // The feed gets a build higher than this checkout's (3).
        let feedPath = world.github.appending(path: "files/v0.2.0/appcast.xml")
        let feed = try world.read(feedPath).replacingOccurrences(of: "<sparkle:version>2<", with: "<sparkle:version>9<")
        try world.write(feed, "github/files/v0.2.0/appcast.xml")
        let result = try await world.run(["--version", "0.3.0", "--dry-run"])
        #expect(result.status != 0)
        #expect(result.output.contains("not newer than build 9"), "\(result.output)")
        #expect(!world.calls.contains("build-app"), "checked before the build")
    }

    @Test func itStopsBeforeCreatingTheReleaseWhenWhatItPublishesHoldsAHomePath() async throws {
        let world = try await PublishFixture()
        let result = try await world.run(["--version", "0.3.0", "--yes"], environment: ["FAKE_HOME_CHECK_FAILS": "1"])
        #expect(result.status != 0)
        #expect(world.calls.contains("check-no-home-paths"), "the feed and the notes are checked")
        #expect(!world.calls.contains("gh release create"))
    }

    @Test func itRefusesAVersionThatIsNotThreeNumbers() async throws {
        let world = try await PublishFixture()
        let result = try await world.run(["--version", "0.3", "--dry-run"])
        #expect(result.status != 0)
        #expect(!world.calls.contains("build-app"))
    }

    // MARK: The script itself

    @Test func itNamesTheRepositoryTheFeedAddressPointsAt() throws {
        let script = try String(contentsOf: repositoryRoot.appending(path: "scripts/publish-update.sh"), encoding: .utf8)
        #expect(script.contains("readonly OWNER=\"ducky8x\""))
        #expect(script.contains("readonly REPO=\"$OWNER/sTools\""))
        #expect(!script.contains("sTools-releases"), "the separate releases repository was never made")
    }

    @Test func itNeverPushesTagsOrReadsThePrivateKey() throws {
        let script = try String(contentsOf: repositoryRoot.appending(path: "scripts/publish-update.sh"), encoding: .utf8)
        let code = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        // A git command that writes, where a command can stand (the start of a line, after ; && || | or $( ); the
        // messages that tell ducky to push are inside quotes and never match.
        let writes = try NSRegularExpression(pattern:
            #"(^|;|&&|\|\||\||\$\()\s*git\s+(-C\s+("[^"]*"|\S+)\s+)?(push|tag|commit|branch|merge|reset|checkout|switch|rebase|stash|add)(\s|$)"#)
        for line in code {
            let text = String(line)
            #expect(writes.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil, "writes to git: \(text)")
            #expect(!text.contains("--ed-key-file"), "the key stays in the keychain: \(text)")
            if text.contains("generate_keys\" --account") {
                #expect(text.contains(" -p") && !text.contains(" -x"), "generate_keys only prints the public key: \(text)")
            }
        }
    }
}
