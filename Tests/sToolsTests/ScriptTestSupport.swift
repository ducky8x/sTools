import Foundation

/// Whether the tests run translated by Rosetta: `sysctl.proc_translated` is 1. It is 0 for a native process and missing on
/// an Intel Mac.
let testsRunTranslated: Bool = {
    var translated: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
}()

/// What to run to start `executable` from a test. A translated test starts the x86_64 half of a universal tool, and Apple's
/// developer tools (`git`, `swift`, `otool` and the rest of what `/usr/bin` hands to `xcrun`) can't start that way here:
/// the Command Line Tools' libxcrun is arm64-only on this Mac. Through `arch -arm64` they, and everything they start,
/// run natively, and the test checks what it always did. `arch` replaces itself with the tool, so a timeout signals the
/// tool itself. A native run and an Intel Mac start the tool as it is.
func nativeCommand(
    _ executable: URL, _ arguments: [String], translated: Bool = testsRunTranslated
) -> (executable: URL, arguments: [String]) {
    guard translated else { return (executable, arguments) }
    return (URL(filePath: "/usr/bin/arch"), ["-arm64", executable.path] + arguments)
}

/// What a script printed (standard output and standard error together) and how it ended.
struct ScriptResult {
    let status: Int32
    let output: String
    /// The script ran past its time limit and was stopped.
    let timedOut: Bool
}

/// A running process the watchdog can stop from another task.
private final class RunningScript: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var stopped = false

    var wasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }
}

/// Runs a script or tool, waits for it without blocking the calling task, and stops it when `timeout` of awake time
/// has passed (`SuspendingClock`, so a sleeping Mac doesn't use the limit up). Its output goes to a file, so a script
/// that prints a lot can't fill a pipe and hang.
///
/// The environment is exactly `environment`: tests give scripts a home folder, a PATH and fakes of their own, so
/// nothing of the real user's reaches them. A translated test starts the script natively (`nativeCommand`).
func runScript(
    _ executable: URL, _ arguments: [String] = [], environment: [String: String],
    currentDirectory: URL? = nil, timeout: Duration = .seconds(240)
) async throws -> ScriptResult {
    let outputFile = FileManager.default.temporaryDirectory.appending(path: "sTools-script-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: outputFile.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { try? FileManager.default.removeItem(at: outputFile) }
    let sink = try FileHandle(forWritingTo: outputFile)
    defer { try? sink.close() }

    let running = RunningScript()
    let command = nativeCommand(executable, arguments)
    running.process.executableURL = command.executable
    running.process.arguments = command.arguments
    running.process.environment = environment
    running.process.currentDirectoryURL = currentDirectory
    running.process.standardInput = FileHandle.nullDevice
    running.process.standardOutput = sink
    running.process.standardError = sink

    let watchdog = Task.detached {
        try? await Task.sleep(for: timeout, clock: SuspendingClock())
        if !Task.isCancelled { running.stop() }
    }
    let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
        running.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
            try running.process.run()
        } catch {
            continuation.resume(returning: -1)
        }
    }
    watchdog.cancel()
    let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
    return ScriptResult(status: status, output: output, timedOut: running.wasStopped)
}

/// Writes an executable script, making its folder first.
func writeExecutable(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
