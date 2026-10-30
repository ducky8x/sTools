import Foundation
import Testing

/// How a test starts a tool when the tests run under Rosetta (`nativeCommand`, used by `runScript` and `run`). The first two
/// check the rule itself. The last two start real tools: they pass in a native run too, and under Rosetta they fail
/// without the rule.
@Suite("Starting tools natively")
struct NativeCommandTests {
    /// The Mac's own architecture, which `hw.optional.arm64` reports from a translated process as well.
    private var macArchitecture: String {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1 ? "arm64" : "x86_64"
    }

    @Test func aTranslatedTestStartsAToolThroughArchForTheNativeArchitecture() {
        let command = nativeCommand(URL(filePath: "/usr/bin/git"), ["-C", "/tmp", "status"], translated: true)
        #expect(command.executable.path == "/usr/bin/arch")
        #expect(command.arguments == ["-arm64", "/usr/bin/git", "-C", "/tmp", "status"])
    }

    @Test func aNativeTestStartsAToolAsItIs() {
        let command = nativeCommand(URL(filePath: "/usr/bin/git"), ["status"], translated: false)
        #expect(command.executable.path == "/usr/bin/git")
        #expect(command.arguments == ["status"])
    }

    @Test func aScriptRunsOnTheMacsOwnArchitectureWhetherOrNotTheTestsAreTranslated() async throws {
        let result = try await runScript(URL(filePath: "/bin/sh"), ["-c", "uname -m"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == macArchitecture)
    }

    /// The environment the release-script tests give git names no developer folder, so the shim looks in the Command Line Tools.
    @Test func gitStartsWithNoDeveloperFolderInTheEnvironment() async throws {
        let result = try await runScript(URL(filePath: "/usr/bin/git"), ["--version"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.hasPrefix("git version"), "\(result.output)")
    }
}
