import Foundation
import Testing
@testable import KeyRebinder

/// These run `/bin/sh` and `/usr/bin/true`-style system tools only, never Karabiner's own tool.
@Suite struct ProcessCommandRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndStatus() async throws {
        let result = try await ProcessCommandRunner().run(shell, ["-c", "printf 'out\\n'; printf 'err' >&2; exit 3"])
        #expect(result == CommandResult(stdout: "out\n", stderr: "err", status: 3))
    }

    @Test func passesArgumentsWithoutShellInterpretation() async throws {
        let result = try await ProcessCommandRunner().run(shell, ["-c", "printf '%s' \"$1\"", "sh", "a b $HOME ✦"])
        #expect(result.stdout == "a b $HOME ✦")
    }

    @Test func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let script = "head -c 300000 /dev/zero | tr '\\0' 'x'; head -c 300000 /dev/zero | tr '\\0' 'y' >&2"
        let result = try await ProcessCommandRunner().run(shell, ["-c", script])
        #expect(result.stdout.count == 300_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func aMissingExecutableIsALaunchFailure() async {
        await #expect {
            try await ProcessCommandRunner().run(URL(fileURLWithPath: "/nonexistent/tool"), [])
        } throws: { error in
            if case CommandRunnerError.launchFailed = error { true } else { false }
        }
    }

    @Test func aHungProcessIsTerminatedAtTheTimeout() async {
        let runner = ProcessCommandRunner(timeout: .milliseconds(300))
        let started = SuspendingClock.now
        await #expect {
            try await runner.run(shell, ["-c", "sleep 30"])
        } throws: { error in
            if case CommandRunnerError.timedOut = error { true } else { false }
        }
        #expect(SuspendingClock.now - started < .seconds(10))
    }
}
