import Foundation
import Testing

/// How `scripts/build-app.sh` keeps a failed build from looking like a finished one: the app is made in a staging
/// folder and replaces `build/<App>.app` only once everything has passed (`scripts/lib/stage-app.sh`). A build that
/// fails leaves the app from the last good build where it was and says that it is not this run's.
@Suite("Stage app")
struct StageAppTests {
    static let library = repositoryRoot.appending(path: "scripts/lib/stage-app.sh")

    private final class Workspace {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-stage-\(UUID().uuidString)")
        var build: URL { folder.appending(path: "build") }
        var stage: URL { build.appending(path: ".staging") }
        var finalApp: URL { build.appending(path: "sTools.app") }
        var stagedApp: URL { stage.appending(path: "sTools.app") }

        init() throws {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        /// An app folder with an Info.plist naming a version and a build, and a file that says which app it is.
        func makeApp(at app: URL, version: String, build: String, marker: String) throws {
            try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            try marker.write(to: app.appending(path: "Contents/marker"), atomically: true, encoding: .utf8)
        }

        func marker(of app: URL) -> String? {
            try? String(contentsOf: app.appending(path: "Contents/marker"), encoding: .utf8)
        }

        func run(_ commands: String) async throws -> ScriptResult {
            try await runScript(
                URL(filePath: "/bin/bash"), ["-c", "ROOT=\"$FOLDER\"\nsource \"$LIB\"\n" + commands],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LIB": StageAppTests.library.path,
                              "FOLDER": folder.path, "TZ": "UTC"],
                timeout: .seconds(60))
        }
    }

    // MARK: Committing

    @Test func theFinishedAppReplacesTheOldOneAndTheOldOneIsKeptOnlyInTheStagingFolder() async throws {
        let world = try Workspace()
        try world.makeApp(at: world.finalApp, version: "0.2.0", build: "773", marker: "old")
        try world.makeApp(at: world.stagedApp, version: "0.3.0", build: "800", marker: "new")
        let result = try await world.run(#"stage_commit "$FOLDER/build/.staging/sTools.app" "$FOLDER/build/sTools.app" "$FOLDER/build/.staging""#)
        #expect(result.status == 0, "\(result.output)")
        #expect(world.marker(of: world.finalApp) == "new")
        #expect(!FileManager.default.fileExists(atPath: world.stagedApp.path), "the staged app moved, it was not copied")
        #expect(world.marker(of: world.stage.appending(path: "replaced-sTools.app")) == "old",
                "the old app waits in the staging folder, which the build removes")
    }

    @Test func withoutAnOldAppTheFinishedOneJustMoves() async throws {
        let world = try Workspace()
        try world.makeApp(at: world.stagedApp, version: "0.3.0", build: "800", marker: "new")
        let result = try await world.run(#"stage_commit "$FOLDER/build/.staging/sTools.app" "$FOLDER/build/sTools.app" "$FOLDER/build/.staging""#)
        #expect(result.status == 0, "\(result.output)")
        #expect(world.marker(of: world.finalApp) == "new")
    }

    @Test func aMoveThatFailsGivesTheOldAppBack() async throws {
        let world = try Workspace()
        try world.makeApp(at: world.finalApp, version: "0.2.0", build: "773", marker: "old")
        // Nothing is staged, so the move cannot happen.
        let result = try await world.run(#"stage_commit "$FOLDER/build/.staging/sTools.app" "$FOLDER/build/sTools.app" "$FOLDER/build/.staging""#)
        #expect(result.status != 0)
        #expect(result.output.contains("could not move the finished app"), "\(result.output)")
        #expect(world.marker(of: world.finalApp) == "old", "the old app is back in its place")
    }

    // MARK: Saying what is left

    @Test func anAppIsDescribedByItsVersionItsBuildAndWhenItWasMade() async throws {
        let world = try Workspace()
        try world.makeApp(at: world.finalApp, version: "0.2.0", build: "773", marker: "old")
        let result = try await world.run(#"stage_describe "$FOLDER/build/sTools.app""#)
        #expect(result.output.hasPrefix("version 0.2.0, build 773, made "), "\(result.output)")
        let none = try await world.run(#"stage_describe "$FOLDER/build/missing.app""#)
        #expect(none.output.isEmpty)
    }

    @Test func aFailedBuildSaysTheOldAppWasNotReplacedAndWhatItIs() async throws {
        let world = try Workspace()
        try world.makeApp(at: world.finalApp, version: "0.2.0", build: "773", marker: "old")
        let result = try await world.run(#"stage_report_failure "$FOLDER/build/sTools.app" 0"#)
        #expect(result.output.contains("build/sTools.app was not replaced"), "\(result.output)")
        #expect(result.output.contains("still the app from an earlier build (version 0.2.0, build 773"), "\(result.output)")
        #expect(result.output.contains("not one made by this run"), "\(result.output)")
        #expect(!result.output.contains(world.folder.path), "the path of the checkout is not printed: \(result.output)")
    }

    @Test func aFailedBuildWithNoAppSaysThereIsNone() async throws {
        let world = try Workspace()
        let result = try await world.run(#"stage_report_failure "$FOLDER/build/sTools.app" 0"#)
        #expect(result.output.contains("the build failed, and there is no build/sTools.app"), "\(result.output)")
    }

    @Test func aBuildThatFinishedSaysNothingAboutAFailure() async throws {
        let world = try Workspace()
        try world.makeApp(at: world.finalApp, version: "0.3.0", build: "800", marker: "new")
        let result = try await world.run(#"stage_report_failure "$FOLDER/build/sTools.app" 1"#)
        #expect(result.output.isEmpty, "\(result.output)")
    }

    // MARK: The build script

    @Test func theBuildScriptReplacesTheAppOnlyAfterItsLastCheck() throws {
        let script = try String(contentsOf: repositoryRoot.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        func position(_ text: String) throws -> String.Index {
            try #require(script.range(of: text)?.lowerBound, "build-app.sh has no \(text)")
        }
        let commit = try position(#"stage_commit "$APP" "$FINAL_APP""#)
        for check in [#"codesign --verify --deep --strict --verbose=2 "$APP""#,
                      #"scripts/check-no-home-paths.sh" "$APP""#,
                      #"Hardened Runtime is not enabled"#] {
            #expect(try position(check) < commit, "\(check) must come before the app is moved into place")
        }
        #expect(script.contains(#"readonly APP="$STAGE/$APP_NAME""#), "every step works on the staged app")
        #expect(!script.contains(#"rm -rf "$FINAL_APP""#), "the app in place is never removed by hand")
    }
}
