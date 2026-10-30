import Foundation
import Testing

/// What a build's number is (`scripts/lib/build-number.sh`): the number of commits on HEAD plus 1000, unless
/// `BUILD_NUMBER` says otherwise. `scripts/build-app.sh` writes it as the app's CFBundleVersion and
/// `scripts/publish-update.sh` as the update feed's sparkle:version, and both ask this one place, so the two agree.
@Suite("Build number")
struct BuildNumberTests {
    static let library = repositoryRoot.appending(path: "scripts/lib/build-number.sh")

    /// A folder with a git repository of a few commits in it, and a plain folder that is no checkout, removed afterwards.
    private final class Checkout {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-number-\(UUID().uuidString)")
        var repo: URL { folder.appending(path: "repo") }
        var plain: URL { folder.appending(path: "plain") }
        private var commits = 0

        private var environment: [String: String] {
            [
                "HOME": folder.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": folder.path + "/",
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
                "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            ]
        }

        static func make(commits: Int) async throws -> Checkout {
            let checkout = Checkout()
            try FileManager.default.createDirectory(at: checkout.repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkout.plain, withIntermediateDirectories: true)
            try await checkout.git(["init", "-q", "-b", "main"])
            for _ in 0..<commits { try await checkout.commit() }
            return checkout
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        private func git(_ arguments: [String]) async throws {
            let result = try await runScript(URL(filePath: "/usr/bin/git"), ["-C", repo.path] + arguments,
                                             environment: environment, timeout: .seconds(60))
            try #require(result.status == 0, "git \(arguments.joined(separator: " ")) failed: \(result.output)")
        }

        func commit() async throws {
            commits += 1
            try "commit \(commits)\n".write(to: repo.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
            try await git(["add", "-A"])
            try await git(["commit", "-q", "-m", "Commit \(commits)"])
        }

        /// What `build_number` prints for a folder, with `BUILD_NUMBER` set to `override` when given, and how it ended.
        func number(of directory: URL, override: String? = nil) async throws -> (text: String, result: ScriptResult) {
            var environment = self.environment
            environment["LIB"] = BuildNumberTests.library.path
            environment["FOLDER"] = directory.path
            if let override { environment["BUILD_NUMBER"] = override }
            let result = try await runScript(URL(filePath: "/bin/bash"), ["-c", #"source "$LIB" && build_number "$FOLDER""#],
                                             environment: environment, timeout: .seconds(60))
            return (result.output.trimmingCharacters(in: .whitespacesAndNewlines), result)
        }
    }

    // MARK: The rule

    @Test func theNumberIsTheCommitCountPlusOneThousand() async throws {
        let checkout = try await Checkout.make(commits: 3)
        let number = try await checkout.number(of: checkout.repo)
        #expect(number.result.status == 0, "\(number.result.output)")
        #expect(number.text == "1003", "3 commits and 1000: \(number.text)")
    }

    @Test func eachCommitRaisesTheNumberByOne() async throws {
        let checkout = try await Checkout.make(commits: 3)
        let before = try await checkout.number(of: checkout.repo).text
        try await checkout.commit()
        let after = try await checkout.number(of: checkout.repo).text
        #expect(before == "1003" && after == "1004", "\(before) then \(after)")
    }

    @Test func aBuildNumberInTheEnvironmentWins() async throws {
        let checkout = try await Checkout.make(commits: 3)
        let number = try await checkout.number(of: checkout.repo, override: "42")
        #expect(number.text == "42", "\(number.text)")
    }

    @Test func anEmptyBuildNumberCountsAsNoneAtAll() async throws {
        let checkout = try await Checkout.make(commits: 3)
        let number = try await checkout.number(of: checkout.repo, override: "")
        #expect(number.text == "1003", "\(number.text)")
    }

    @Test func outsideAGitCheckoutTheCountIsOne() async throws {
        let checkout = try await Checkout.make(commits: 1)
        let number = try await checkout.number(of: checkout.plain)
        #expect(number.result.status == 0, "\(number.result.output)")
        #expect(number.text == "1001", "one commit and 1000: \(number.text)")
    }

    @Test func aBuildNumberThatIsNotAWholeNumberIsRefused() async throws {
        let checkout = try await Checkout.make(commits: 3)
        for bad in ["12a", "-5", "1.5", " 7"] {
            let number = try await checkout.number(of: checkout.repo, override: bad)
            #expect(number.result.status != 0, "\"\(bad)\" is refused")
            #expect(number.text.contains("BUILD_NUMBER must be a whole number"), "\(number.text)")
        }
    }

    // MARK: The two scripts

    @Test func theAppAndTheFeedGetTheSameNumberForTheSameCommit() async throws {
        let world = try await PublishFixture()
        // The feed's number: publish-update.sh, with a stand-in for the build itself.
        let published = try await world.run(["--version", "0.3.0", "--dry-run"])
        #expect(published.status == 0, "\(published.output)")
        let feed = try XMLDocument(contentsOf: world.published("v0.3.0").appending(path: "appcast.xml"))
        let feedNumber = try feed.nodes(forXPath: "/rss/channel/item[1]/sparkle:version").first?.stringValue
        #expect(world.calls.contains("BUILD_NUMBER=\(feedNumber ?? "none")"), "the build is made with the number the feed gets")

        // The app's number: the real build-app.sh in the same checkout, stopped right after it names it.
        let built = try await world.runRealBuildApp()
        let pattern = try NSRegularExpression(pattern: #"==> Building \(debug\): version \S+, build (\d+)"#)
        let match = pattern.firstMatch(in: built.output, range: NSRange(built.output.startIndex..., in: built.output))
        let appNumber = match.flatMap { Range($0.range(at: 1), in: built.output) }.map { String(built.output[$0]) }
        #expect(appNumber != nil, "build-app.sh names its build number: \(built.output)")
        #expect(appNumber == feedNumber, "app \(appNumber ?? "none"), feed \(feedNumber ?? "none")")
        #expect(feedNumber == "1003", "the checkout has 3 commits")
    }

    @Test func aBuildNumberInTheEnvironmentReachesTheBuildAndTheFeedAndIsSaid() async throws {
        let world = try await PublishFixture()
        let published = try await world.run(["--version", "0.3.0", "--dry-run"], environment: ["BUILD_NUMBER": "2000"])
        #expect(published.status == 0, "\(published.output)")
        #expect(world.calls.contains("VERSION=0.3.0 BUILD_NUMBER=2000"))
        let feed = try XMLDocument(contentsOf: world.published("v0.3.0").appending(path: "appcast.xml"))
        #expect(try feed.nodes(forXPath: "/rss/channel/item[1]/sparkle:version").first?.stringValue == "2000")
        #expect(published.output.contains("BUILD_NUMBER is set"), "the script says why the number is not the count: \(published.output)")
    }

    @Test func neitherScriptCountsCommitsItself() throws {
        for name in ["build-app.sh", "publish-update.sh"] {
            let script = try String(contentsOf: repositoryRoot.appending(path: "scripts/\(name)"), encoding: .utf8)
            let code = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            #expect(script.contains("scripts/lib/build-number.sh"), "\(name) sources the one place that numbers a build")
            #expect(code.contains { $0.contains(#"$(build_number "$ROOT")"#) }, "\(name) asks it for the number")
            #expect(!code.contains { $0.contains("rev-list --count HEAD") }, "\(name) counts the commits itself")
        }
    }
}
