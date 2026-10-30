import Foundation
import Testing

/// `run_with_limit` in `scripts/lib/run-with-limit.sh`, which stops a command that runs too long: `scripts/build-dmg.sh`
/// uses it for `hdiutil create` and `hdiutil convert`, which can hang for good when the disk image helper is stuck.
/// The tests run it on `sleep` and `perl`, never on hdiutil.
@Suite("Run with limit")
struct RunWithLimitTests {
    static let library = repositoryRoot.appending(path: "scripts/lib/run-with-limit.sh")

    private func run(_ commands: String, timeout: Duration = .seconds(60)) async throws -> ScriptResult {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await runScript(
            URL(filePath: "/bin/bash"), ["-c", "source \"$LIB\"\n" + commands],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": folder.path + "/", "LIB": Self.library.path],
            timeout: timeout)
    }

    @Test func aCommandThatFinishesInTimeKeepsItsOwnStatusAndOutput() async throws {
        let result = try await run(#"run_with_limit 30 "the test" bash -c 'echo fine; exit 3'; echo "status $?""#)
        #expect(result.output == "fine\nstatus 3\n", "\(result.output)")
    }

    @Test func aCommandThatSucceedsReturnsZero() async throws {
        let result = try await run(#"run_with_limit 30 "the test" true; echo "status $?""#)
        #expect(result.output == "status 0\n", "\(result.output)")
    }

    @Test func aCommandThatRunsTooLongIsStoppedAndTheMessageSaysSo() async throws {
        let started = ContinuousClock.now
        // 37 seconds is far past the limit of 1 and unlike any other sleep that might be running.
        let result = try await run(#"run_with_limit 1 "hdiutil create" sleep 37; echo "status $?"; pgrep -f '^sleep 37$' || echo gone"#)
        let took = ContinuousClock.now - started
        #expect(result.output.contains("error: hdiutil create did not finish within 1 seconds, so it was stopped."), "\(result.output)")
        #expect(result.output.contains("status 124"), "\(result.output)")
        #expect(result.output.contains("gone"), "the command is no longer running: \(result.output)")
        #expect(!result.output.contains("Terminated"), "bash's own notice about the stopped job is not shown: \(result.output)")
        #expect(took < .seconds(30), "it did not wait for the command: \(took)")
    }

    @Test func aCommandThatIgnoresTheFirstSignalIsKilledAfterFiveMoreSeconds() async throws {
        let result = try await run(#"run_with_limit 1 "the test" perl -e '$SIG{TERM} = "IGNORE"; sleep 53'; echo "status $?"; pgrep -f '^perl -e .*sleep 53' || echo gone"#)
        #expect(result.output.contains("did not finish within 1 seconds"), "\(result.output)")
        #expect(result.output.contains("status 124"), "\(result.output)")
        #expect(result.output.contains("gone"), "\(result.output)")
    }

    @Test func aQuickCommandReturnsAtOnceNotAfterTheLimit() async throws {
        let started = ContinuousClock.now
        let result = try await run(#"run_with_limit 600 "the test" true; echo "status $?""#)
        let took = ContinuousClock.now - started
        #expect(result.output == "status 0\n", "\(result.output)")
        #expect(took < .seconds(10), "it waited for the limit: \(took)")
    }

    @Test func buildDMGBoundsTheTwoLongHdiutilSteps() throws {
        let script = try String(contentsOf: repositoryRoot.appending(path: "scripts/build-dmg.sh"), encoding: .utf8)
        let code = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        #expect(script.contains("scripts/lib/run-with-limit.sh"))
        #expect(script.contains(#"run_with_limit "$HDIUTIL_LIMIT" "hdiutil $1" hdiutil "$@""#), "the one place hdiutil runs")
        let starts = { (line: Substring, prefix: String) in line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
        for step in ["create", "convert"] {
            #expect(code.contains { starts($0, "run_hdiutil \(step) ") }, "build-dmg.sh runs hdiutil \(step) with a limit")
            #expect(!code.contains { starts($0, "hdiutil \(step) ") }, "hdiutil \(step) also runs without a limit")
        }
    }
}
