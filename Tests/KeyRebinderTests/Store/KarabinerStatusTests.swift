import Foundation
import Testing
@testable import KeyRebinder

private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func note(_ name: String) { lock.withLock { names.append(name) } }
    var called: [String] { lock.withLock { names } }
}

@Suite struct KarabinerStatusTests {
    private func status(
        app: Bool = true, version: String? = "16.3.0", config: Bool = true, log: ProbeLog = ProbeLog()
    ) -> KarabinerStatus {
        KarabinerStatus(probes: KarabinerProbes(
            appBundleExists: { log.note("app"); return app },
            cliVersion: { log.note("cli"); return version },
            configReadable: { log.note("config"); return config }
        ))
    }

    @Test func readyWhenEverythingChecksOut() async {
        let log = ProbeLog()
        let result = await status(log: log).evaluate()
        #expect(result == .ready)
        #expect(result.isReady)
        #expect(log.called == ["app", "cli", "config"])
    }

    @Test func notInstalledComesFirstAndStopsTheChecks() async {
        let log = ProbeLog()
        #expect(await status(app: false, version: nil, config: false, log: log).evaluate() == .notInstalled)
        #expect(log.called == ["app"])
    }

    @Test func aSilentCLIMeansNotRunning() async {
        let log = ProbeLog()
        #expect(await status(version: nil, config: false, log: log).evaluate() == .notRunning)
        #expect(log.called == ["app", "cli"])
    }

    @Test func anUnreadableVersionMeansNotRunning() async {
        #expect(await status(version: "gibberish").evaluate() == .notRunning)
    }

    @Test(arguments: ["15.9.0-beta", "15.99.0", "9.0.0", "15"])
    func oldVersionsAreRejectedWithTheVersionFound(found: String) async {
        let log = ProbeLog()
        #expect(await status(version: found, config: false, log: log).evaluate() == .versionTooOld(found: found))
        #expect(log.called == ["app", "cli"])
    }

    @Test(arguments: ["16.0.0", "16.0", "16.3.0", "17.1.0-beta", "100.0"])
    func supportedVersionsPass(found: String) async {
        #expect(await status(version: found).evaluate() == .ready)
    }

    @Test func anUnreadableConfigComesLast() async {
        #expect(await status(config: false).evaluate() == .configUnreadable)
    }

    @Test func everyFailureHasOneSentenceOfAdvice() {
        let failures: [KarabinerRequirement] = [.notInstalled, .notRunning, .versionTooOld(found: "15.9.0"), .configUnreadable]
        for failure in failures {
            let text = failure.fixText
            #expect(!text.isEmpty)
            #expect(text.hasSuffix("."))
            #expect(!text.dropLast().contains(". "), "one sentence only")
            #expect(!failure.isReady)
        }
        #expect(KarabinerRequirement.versionTooOld(found: "15.9.0").fixText.contains("15.9.0"))
        #expect(KarabinerRequirement.ready.fixText.isEmpty)
    }
}

@Suite struct KarabinerLiveProbesTests {
    private let cliURL = URL(fileURLWithPath: "/fake/karabiner_cli")

    private func probes(_ directory: TempDirectory, cliOutput: String, status: Int32 = 0, configText: String?) throws -> KarabinerProbes {
        let config = directory.url.appending(path: "karabiner.json")
        if let configText { try Data(configText.utf8).write(to: config) }
        let cli = KarabinerCLI(runner: FakeCommandRunner(stdout: cliOutput, status: status), cliURL: cliURL)
        return .live(cli: cli, configURL: config, appURL: directory.url)
    }

    @Test func liveProbesReadTheGivenPaths() async throws {
        try await withTempDirectory { directory in
            let live = try probes(directory, cliOutput: "16.3.0\n", configText: #"{"profiles":[]}"#)
            #expect(live.appBundleExists())
            #expect(await live.cliVersion() == "16.3.0")
            #expect(live.configReadable())
            #expect(await KarabinerStatus(probes: live).evaluate() == .ready)
        }
    }

    @Test func liveProbesNoticeProblems() async throws {
        try await withTempDirectory { directory in
            let missingApp = KarabinerProbes.live(
                cli: KarabinerCLI(runner: FakeCommandRunner(stdout: ""), cliURL: cliURL),
                configURL: directory.url.appending(path: "none.json"),
                appURL: directory.url.appending(path: "Nope.app")
            )
            #expect(!missingApp.appBundleExists())
            #expect(!missingApp.configReadable())

            let failing = try probes(directory, cliOutput: "", status: 1, configText: "[1]")
            #expect(await failing.cliVersion() == nil)
            #expect(!failing.configReadable())

            let invalid = try probes(directory, cliOutput: "16.0.0", configText: "{ nope")
            #expect(!invalid.configReadable())
        }
    }
}
