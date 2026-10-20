import Foundation

/// What a finished command printed and how it ended.
public struct CommandResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var status: Int32

    public init(stdout: String, stderr: String = "", status: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

/// Runs an executable and waits for it. Tests inject a fake; ``ProcessCommandRunner`` is the real one.
public protocol CommandRunner: Sendable {
    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult
}

/// Why a command could not be run to completion.
public enum CommandRunnerError: Error, Equatable, Sendable {
    /// The process could not be started (missing file, no permission).
    case launchFailed(String)
    /// The process was still running after the time limit and was terminated.
    case timedOut(seconds: Double)
}

/// Runs commands with `Process`, reading both output streams while the process runs so large output cannot
/// block it, and terminating a process that outlives `timeout`.
public struct ProcessCommandRunner: CommandRunner {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    public func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        let limit = timeout
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runBlocking(executable, args, timeout: limit) })
            }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data
        init(_ value: Data) { self.value = value }
        func set(_ newValue: Data) { lock.withLock { value = newValue } }
        func get() -> Data { lock.withLock { value } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var isRaised: Bool { lock.withLock { raised } }
    }

    private static func runBlocking(_ executable: URL, _ args: [String], timeout: Duration) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }

        let outBox = Box(Data())
        let errBox = Box(Data())
        let readers = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            readers.enter()
            DispatchQueue.global().async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }

        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.raise()
                process.terminate()
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)

        process.waitUntilExit()
        readers.wait()
        watchdog.cancel()
        if timedOut.isRaised { throw CommandRunnerError.timedOut(seconds: seconds) }
        return CommandResult(
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            status: process.terminationStatus
        )
    }
}
