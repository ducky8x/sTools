import Darwin
import Foundation

/// Restarts copies for real: reads their launch from the process table and starts them again with `posix_spawn`.
struct LiveNBBCopiesRestarter {
    /// Whether `launch` can be started again: its program is still there and runnable, and so is its folder.
    static func canStart(_ launch: NBBLaunch) -> Bool {
        var isFolder: ObjCBool = false
        let files = FileManager.default
        return files.isExecutableFile(atPath: launch.executablePath)
            && files.fileExists(atPath: launch.executablePath, isDirectory: &isFolder) && !isFolder.boolValue
            && files.fileExists(atPath: launch.workingDirectory, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Starts `launch` as it was, detached from sTools: in a session of its own, with standard input and output on
    /// /dev/null, no other descriptor of sTools', every signal at its default and none blocked. The reaper collects it
    /// when it exits. Nil when it couldn't start.
    static func start(_ launch: NBBLaunch) -> pid_t? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var noSignals = sigset_t()
        var everySignal = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&everySignal)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              posix_spawnattr_setsigmask(&attributes, &noSignals) == 0,
              posix_spawnattr_setsigdefault(&attributes, &everySignal) == 0,
              posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0,
              changeFolder(&actions, to: launch.workingDirectory) == 0 else { return nil }
        var pid: pid_t = 0
        let result = withCStrings(launch.arguments) { arguments in
            withCStrings(launch.environment) { environment in
                posix_spawn(&pid, launch.executablePath, &actions, &attributes, arguments, environment)
            }
        }
        guard result == 0, pid > 0 else { return nil }
        NBBChildReaper.shared.collect(pid)
        return pid
    }

    private static func changeFolder(_ actions: inout posix_spawn_file_actions_t?, to path: String) -> Int32 {
        if #available(macOS 26, *) { return posix_spawn_file_actions_addchdir(&actions, path) }
        return posix_spawn_file_actions_addchdir_np(&actions, path)
    }

    /// `strings` as a C array ending in a null pointer, for as long as `body` runs.
    private static func withCStrings<Result>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
        let copies = strings.map { strdup($0) } + [nil]
        defer { copies.forEach { free($0) } }
        return copies.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// Collects the processes a restart started once they exit, so none is left a zombie while sTools runs. Each gets a
/// process-exit source on the reaper's own queue, whose handler calls `waitpid` without waiting: nothing blocks Swift's
/// concurrency pool or the main actor. A process sTools quits before it exits goes to launchd as usual.
final class NBBChildReaper: @unchecked Sendable {
    static let shared = NBBChildReaper()

    private let queue = DispatchQueue(label: "com.ducky8x.sTools.nbb-reaper")
    private let lock = NSLock()
    private var sources: [pid_t: any DispatchSourceProcess] = [:]

    /// Watches `pid`, a child of sTools, and collects it once it exits.
    func collect(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.reap(pid) }
        lock.withLock { sources[pid] = source }
        source.resume()
        // A process that exited before its source was armed is never reported by it.
        queue.async { [weak self] in self?.reap(pid) }
    }

    /// Whether `pid` is still waited for. For tests.
    func isWatching(_ pid: pid_t) -> Bool { lock.withLock { sources[pid] != nil } }

    private func reap(_ pid: pid_t) {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid || (result == -1 && errno == ECHILD) else { return }
        lock.withLock { sources.removeValue(forKey: pid) }?.cancel()
    }
}
