import Foundation
import Testing

/// The version `scripts/build-app.sh` gives an app when nobody says (`VERSION`): the release line being worked on. Moving
/// to the next line changes this test and the script's default together; `scripts/publish-update.sh` takes its version on
/// the command line and has no default. The script is the real one, run in a throwaway checkout with a `swift` that refuses
/// to build, so it stops right after it names the version and nothing is built.
@Suite("Build version")
struct BuildVersionTests {
    private static let namesTheVersion = #"==> Building \(debug\): version (\S+), build \d+"#

    private func version(in output: String) throws -> String? {
        let pattern = try NSRegularExpression(pattern: Self.namesTheVersion)
        let match = pattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output))
        return match.flatMap { Range($0.range(at: 1), in: output) }.map { String(output[$0]) }
    }

    @Test func withoutAVersionItBuildsTheCurrentReleaseLine() async throws {
        let world = try await PublishFixture()
        let built = try await world.runRealBuildApp()
        #expect(try version(in: built.output) == "0.2.0", "\(built.output)")
    }

    @Test func aVersionInTheEnvironmentWins() async throws {
        let world = try await PublishFixture()
        let built = try await world.runRealBuildApp(environment: ["VERSION": "0.9.1"])
        #expect(try version(in: built.output) == "0.9.1", "\(built.output)")
    }
}
