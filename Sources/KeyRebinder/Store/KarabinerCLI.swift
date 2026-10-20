import Foundation

/// Why a `karabiner_cli` call failed.
public enum KarabinerCLIError: Error, Equatable, Sendable {
    /// The command ended with a non-zero status; `message` is what it printed.
    case commandFailed(status: Int32, message: String)
    /// The command succeeded but printed something that cannot be understood.
    case unexpectedOutput(String)
    /// `--select-profile` found no profile with this name.
    case profileNotFound(String)
    /// The lint path is missing or contains characters `karabiner_cli` would read as a glob pattern.
    case invalidLintPath(String)
}

extension KarabinerCLIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let message):
            message.isEmpty ? "Karabiner's command line tool failed (exit \(status))." : "Karabiner's command line tool failed (exit \(status)): \(message)"
        case .unexpectedOutput(let output):
            "Karabiner's command line tool printed something unexpected: \(output)"
        case .profileNotFound(let name):
            "Karabiner-Elements has no profile named \"\(name)\"."
        case .invalidLintPath(let reason):
            reason
        }
    }
}

/// The result of `--lint-complex-modifications`.
public enum KarabinerLintResult: Equatable, Sendable {
    case valid
    /// One entry per line Karabiner printed.
    case invalid(messages: [String])
}

/// Wraps the `karabiner_cli` commands sTools uses.
public struct KarabinerCLI: Sendable {
    public static let defaultCLIURL = URL(
        fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    )

    private let runner: any CommandRunner
    private let cliURL: URL
    private let fileExists: @Sendable (URL) -> Bool

    public init(runner: any CommandRunner, cliURL: URL = KarabinerCLI.defaultCLIURL) {
        self.init(runner: runner, cliURL: cliURL, fileExists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    init(runner: any CommandRunner, cliURL: URL, fileExists: @escaping @Sendable (URL) -> Bool) {
        self.runner = runner
        self.cliURL = cliURL
        self.fileExists = fileExists
    }

    /// The version text `--version` prints, e.g. "16.3.0".
    public func version() async throws -> String {
        let output = try await succeed(["--version"])
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KarabinerVersion(text) != nil else { throw KarabinerCLIError.unexpectedOutput(text) }
        return text
    }

    /// The selected profile's name (`--show-current-profile-name`); may be empty if the profile is unnamed.
    public func currentProfileName() async throws -> String {
        let lines = Self.lines(try await succeed(["--show-current-profile-name"]).stdout)
        guard lines.count == 1 else { throw KarabinerCLIError.unexpectedOutput(lines.joined(separator: "\n")) }
        return lines[0]
    }

    /// Every profile name in file order (`--list-profile-names`).
    public func listProfileNames() async throws -> [String] {
        let lines = Self.lines(try await succeed(["--list-profile-names"]).stdout)
        guard !lines.isEmpty else { throw KarabinerCLIError.unexpectedOutput("no profile names") }
        return lines
    }

    /// Makes `name` the selected profile (`--select-profile`). The tool exits 0 when the name is unknown,
    /// so that case is recognized from its message.
    public func selectProfile(_ name: String) async throws {
        let output = try await succeed(["--select-profile", name])
        if (output.stdout + output.stderr).contains("is not found") {
            throw KarabinerCLIError.profileNotFound(name)
        }
    }

    /// Validates a complex-modifications JSON file (`--lint-complex-modifications`, which takes the
    /// `{"title": …, "rules": […]}` asset format). The tool reads its argument as a glob pattern and reports
    /// success when nothing matches, so the file must exist and its path must be free of glob characters.
    public func lintComplexModifications(path: URL) async throws -> KarabinerLintResult {
        let filePath = path.path
        guard !filePath.contains(where: { "*?[]{}\\".contains($0) }) else {
            throw KarabinerCLIError.invalidLintPath("The file path contains characters Karabiner would read as a pattern: \(filePath)")
        }
        guard fileExists(path) else {
            throw KarabinerCLIError.invalidLintPath("There is no file to check at \(filePath).")
        }
        let result = try await runner.run(cliURL, ["--lint-complex-modifications", filePath, "--silent"])
        switch result.status {
        case 0: return .valid
        case 1:
            let messages = Self.lines(result.stdout + result.stderr)
            return .invalid(messages: messages.isEmpty ? ["Karabiner rejected the rules without saying why."] : messages)
        default:
            throw KarabinerCLIError.commandFailed(status: result.status, message: Self.message(result))
        }
    }

    // MARK: Helpers

    func succeed(_ args: [String]) async throws -> CommandResult {
        let result = try await runner.run(cliURL, args)
        guard result.status == 0 else {
            throw KarabinerCLIError.commandFailed(status: result.status, message: Self.message(result))
        }
        return result
    }

    private static func message(_ result: CommandResult) -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits output into lines, dropping the one final line terminator and nothing else, so names with
    /// leading or trailing spaces survive. Empty output has no lines.
    private static func lines(_ output: String) -> [String] {
        var text = Substring(output)
        guard !text.isEmpty else { return [] }
        if text.hasSuffix("\n") { text = text.dropLast() }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
