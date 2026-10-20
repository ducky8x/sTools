import Foundation
import Testing
@testable import KeyRebinder

/// Answers calls from a queue (the last answer repeats) and records what was asked.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable {
        var executable: URL
        var args: [String]
    }

    private let lock = NSLock()
    private var responses: [Result<CommandResult, any Error>]
    private var recorded: [Call] = []

    init(_ responses: Result<CommandResult, any Error>...) {
        self.responses = responses
    }

    convenience init(stdout: String, stderr: String = "", status: Int32 = 0) {
        self.init(.success(CommandResult(stdout: stdout, stderr: stderr, status: status)))
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        let next = lock.withLock { () -> Result<CommandResult, any Error> in
            recorded.append(Call(executable: executable, args: args))
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
        return try next.get()
    }
}

@Suite struct KarabinerCLITests {
    private let cli = URL(fileURLWithPath: "/fake/karabiner_cli")

    private func make(_ runner: FakeCommandRunner, fileExists: @escaping @Sendable (URL) -> Bool = { _ in true }) -> KarabinerCLI {
        KarabinerCLI(runner: runner, cliURL: cli, fileExists: fileExists)
    }

    @Test func defaultCLIPath() {
        #expect(KarabinerCLI.defaultCLIURL.path == "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
    }

    @Test func versionIsTrimmed() async throws {
        let runner = FakeCommandRunner(stdout: "16.3.0\n")
        #expect(try await make(runner).version() == "16.3.0")
        #expect(runner.calls == [.init(executable: cli, args: ["--version"])])
    }

    @Test func versionRejectsNonsense() async {
        let runner = FakeCommandRunner(stdout: "usage: karabiner_cli [options]\n")
        await #expect(throws: KarabinerCLIError.unexpectedOutput("usage: karabiner_cli [options]")) {
            try await make(runner).version()
        }
    }

    @Test func currentProfileNameDropsOnlyTheLineTerminator() async throws {
        let runner = FakeCommandRunner(stdout: "  Speed run \n")
        #expect(try await make(runner).currentProfileName() == "  Speed run ")
        #expect(runner.calls.first?.args == ["--show-current-profile-name"])
    }

    @Test func currentProfileNameKeepsUnicode() async throws {
        let runner = FakeCommandRunner(stdout: "Stage ✦ 日本語\n")
        #expect(try await make(runner).currentProfileName() == "Stage ✦ 日本語")
    }

    @Test func currentProfileNameMayBeEmpty() async throws {
        let runner = FakeCommandRunner(stdout: "\n")
        #expect(try await make(runner).currentProfileName() == "")
    }

    @Test func currentProfileNameWithNoOutputIsUnexpected() async {
        let runner = FakeCommandRunner(stdout: "")
        await #expect(throws: KarabinerCLIError.unexpectedOutput("")) { try await make(runner).currentProfileName() }
    }

    @Test func listsProfileNamesInOrder() async throws {
        let runner = FakeCommandRunner(stdout: "Default profile\nÉcran 日本\n\nlast \n")
        #expect(try await make(runner).listProfileNames() == ["Default profile", "Écran 日本", "", "last "])
        #expect(runner.calls.first?.args == ["--list-profile-names"])
    }

    @Test func listProfileNamesToleratesAMissingFinalNewline() async throws {
        #expect(try await make(FakeCommandRunner(stdout: "a\nb")).listProfileNames() == ["a", "b"])
    }

    @Test func emptyProfileListIsUnexpected() async {
        await #expect(throws: KarabinerCLIError.unexpectedOutput("no profile names")) {
            try await make(FakeCommandRunner(stdout: "")).listProfileNames()
        }
    }

    @Test func nonZeroExitIsReportedWithItsMessage() async {
        let runner = FakeCommandRunner(stdout: "", stderr: "boom\n", status: 3)
        await #expect(throws: KarabinerCLIError.commandFailed(status: 3, message: "boom")) {
            try await make(runner).listProfileNames()
        }
    }

    @Test func nonZeroExitFallsBackToStdout() async {
        let runner = FakeCommandRunner(stdout: "error parsing options: x\n", status: 2)
        await #expect(throws: KarabinerCLIError.commandFailed(status: 2, message: "error parsing options: x")) {
            try await make(runner).version()
        }
    }

    @Test func runnerFailuresPropagate() async {
        let runner = FakeCommandRunner(.failure(CommandRunnerError.launchFailed("no such file")))
        await #expect(throws: CommandRunnerError.launchFailed("no such file")) { try await make(runner).version() }
    }

    @Test func selectsAProfileByNameAsOneArgument() async throws {
        let runner = FakeCommandRunner(stdout: "")
        try await make(runner).selectProfile("--odd name 日本")
        #expect(runner.calls == [.init(executable: cli, args: ["--select-profile", "--odd name 日本"])])
    }

    @Test func selectingAnUnknownProfileIsDetectedFromTheMessage() async {
        let runner = FakeCommandRunner(stdout: "[error] `Nope` is not found.\n")
        await #expect(throws: KarabinerCLIError.profileNotFound("Nope")) { try await make(runner).selectProfile("Nope") }
    }

    @Test func selectingAnUnknownProfileIsDetectedOnStderrToo() async {
        let runner = FakeCommandRunner(stdout: "", stderr: "[error] `Nope` is not found.\n")
        await #expect(throws: KarabinerCLIError.profileNotFound("Nope")) { try await make(runner).selectProfile("Nope") }
    }

    @Test func selectFailureSurfacesTheExitStatus() async {
        let runner = FakeCommandRunner(stdout: "", stderr: "denied", status: 1)
        await #expect(throws: KarabinerCLIError.commandFailed(status: 1, message: "denied")) {
            try await make(runner).selectProfile("a")
        }
    }

    @Test func lintAcceptsAValidFile() async throws {
        let runner = FakeCommandRunner(stdout: "")
        let file = URL(fileURLWithPath: "/tmp/rules with space.json")
        #expect(try await make(runner).lintComplexModifications(path: file) == .valid)
        #expect(runner.calls == [.init(executable: cli, args: ["--lint-complex-modifications", "/tmp/rules with space.json", "--silent"])])
    }

    @Test func lintReturnsEachMessageOnExit1() async throws {
        let runner = FakeCommandRunner(stdout: "rules[0]: `manipulators` is required\nsecond problem\n", status: 1)
        let result = try await make(runner).lintComplexModifications(path: URL(fileURLWithPath: "/tmp/r.json"))
        #expect(result == .invalid(messages: ["rules[0]: `manipulators` is required", "second problem"]))
    }

    @Test func lintWithoutMessagesStillSaysInvalid() async throws {
        let runner = FakeCommandRunner(stdout: "", status: 1)
        let result = try await make(runner).lintComplexModifications(path: URL(fileURLWithPath: "/tmp/r.json"))
        #expect(result == .invalid(messages: ["Karabiner rejected the rules without saying why."]))
    }

    @Test func lintOtherExitCodesAreFailures() async {
        let runner = FakeCommandRunner(stdout: "error parsing options", status: 2)
        await #expect(throws: KarabinerCLIError.commandFailed(status: 2, message: "error parsing options")) {
            try await make(runner).lintComplexModifications(path: URL(fileURLWithPath: "/tmp/r.json"))
        }
    }

    @Test func lintRefusesAMissingFileBecauseTheToolWouldSayOK() async {
        let runner = FakeCommandRunner(stdout: "")
        await #expect {
            try await make(runner, fileExists: { _ in false }).lintComplexModifications(path: URL(fileURLWithPath: "/tmp/gone.json"))
        } throws: { error in
            if case KarabinerCLIError.invalidLintPath = error { true } else { false }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func lintRefusesPathsThatLookLikeGlobs() async {
        let runner = FakeCommandRunner(stdout: "")
        for path in ["/tmp/*.json", "/tmp/a?.json", "/tmp/[x]/r.json", "/tmp/{a,b}.json"] {
            await #expect {
                try await make(runner).lintComplexModifications(path: URL(fileURLWithPath: path))
            } throws: { error in
                if case KarabinerCLIError.invalidLintPath = error { true } else { false }
            }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func lintChecksTheRealFileSystemByDefault() async throws {
        try await withTempDirectory { directory in
            let file = directory.url.appending(path: "rules.json")
            try Data("{}".utf8).write(to: file)
            let runner = FakeCommandRunner(stdout: "")
            let real = KarabinerCLI(runner: runner, cliURL: cli)
            #expect(try await real.lintComplexModifications(path: file) == .valid)
            await #expect(throws: KarabinerCLIError.self) {
                try await real.lintComplexModifications(path: directory.url.appending(path: "missing.json"))
            }
        }
    }
}

@Suite struct ConnectedDeviceTests {
    /// Shaped like Karabiner 16.3's `--list-connected-devices` output.
    static let sample = """
    [
        {
            "device_address": "",
            "device_id": 4294969283,
            "device_identifiers": { "is_keyboard": true, "product_id": 832, "vendor_id": 1452 },
            "is_built_in_keyboard": true,
            "location_id": 161,
            "manufacturer": "Apple Inc.",
            "product": "Apple Internal Keyboard / Trackpad",
            "transport": "FIFO"
        },
        {
            "device_id": 4294969284,
            "device_identifiers": { "is_keyboard": true, "product_id": 832, "vendor_id": 1452 },
            "manufacturer": "Apple Inc.",
            "product": "Apple Internal Keyboard / Trackpad"
        },
        {
            "device_id": 4294969300,
            "device_identifiers": { "is_pointing_device": true, "product_id": 49271, "vendor_id": 1133 },
            "manufacturer": "Logitech",
            "product": ""
        },
        {
            "device_id": 4294969400,
            "device_identifiers": { "is_consumer": true, "product_id": 5, "vendor_id": 9 },
            "product": "Media remote"
        },
        {
            "device_id": 4294969500,
            "device_identifiers": { "is_keyboard": true, "is_virtual_device": true, "product_id": 1, "vendor_id": 2 },
            "product": "Karabiner DriverKit VirtualHIDKeyboard"
        }
    ]
    """

    @Test func keepsOneEntryPerKeyboardOrMouse() throws {
        let devices = try ConnectedDevice.parseList(Self.sample)
        #expect(devices.map(\.identifiers) == [
            DeviceIdentifiers(vendorID: 1452, productID: 832, isKeyboard: true),
            DeviceIdentifiers(vendorID: 1133, productID: 49271, isPointingDevice: true),
        ])
        #expect(devices[0].isBuiltInKeyboard)
        #expect(devices[0].displayName == "Apple Internal Keyboard / Trackpad (keyboard)")
        #expect(devices[1].displayName == "Logitech (mouse)")
    }

    @Test func theCLIIsAskedAndAnswersParse() async throws {
        let runner = FakeCommandRunner(stdout: Self.sample)
        let cli = KarabinerCLI(runner: runner, cliURL: URL(fileURLWithPath: "/fake/karabiner_cli"), fileExists: { _ in true })
        #expect(try await cli.listConnectedDevices().count == 2)
        #expect(runner.calls.map(\.args) == [["--list-connected-devices"]])
    }

    @Test func outputThatIsNotAListIsRejected() {
        #expect(throws: KarabinerCLIError.self) { try ConnectedDevice.parseList("{}") }
    }
}
