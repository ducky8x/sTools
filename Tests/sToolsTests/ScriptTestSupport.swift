import Foundation

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
/// nothing of the real user's reaches them.
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
    running.process.executableURL = executable
    running.process.arguments = arguments
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
