import AppKit
import Darwin
import Foundation

/// What restarting a copy does to processes. The live one reads the process table, asks through AppKit and starts with
/// `posix_spawn`; tests use a fake that never touches a real process.
protocol NBBCopiesRestarting: Sendable {
    /// How `copy` was started, or nil when that can't be read.
    func launch(of copy: NBBCopy) -> NBBLaunch?
    /// Whether `launch`'s program and folder are still there.
    func canStart(_ launch: NBBLaunch) -> Bool
    /// Asks `copy` to quit, as its Quit menu would. False when it couldn't be asked.
    func askToQuit(_ copy: NBBCopy) async -> Bool
    /// Sends `copy` the terminate signal, which runs Ninjabrain Bot's shutdown as a quit does. Never the kill signal,
    /// which would lose its state.
    func signalToQuit(_ copy: NBBCopy)
    /// Whether process `pid` runs, and, given `startedAt`, is still the process that started then.
    func isRunning(_ pid: Int32, startedAt: Date?) -> Bool
    /// Whether any process of this user listens on `port`.
    func isListened(on port: UInt16) -> Bool
    func listens(_ pid: Int32, on port: UInt16) -> Bool
    /// Starts `launch` again, detached from sTools. The new process's number, or nil when it couldn't start.
    func start(_ launch: NBBLaunch) -> Int32?
}

/// How long each of a restart's waits lasts, and how often it looks.
struct NBBRestartTiming: Sendable {
    /// How long a copy has to quit once asked, before it gets the terminate signal.
    var quitGrace: Duration = .seconds(3)
    /// How long it has once signaled.
    var signalGrace: Duration = .seconds(5)
    /// How long the API's port has to come free once the copy holding it has quit.
    var portGrace: Duration = .seconds(2)
    /// How long the new process has to take the API: Java starts slowly.
    var apiGrace: Duration = .seconds(20)
    var look: Duration = .milliseconds(100)
}

/// Where a restart has got to, for the page.
enum NBBRestartStep: Equatable, Sendable {
    /// A copy quit.
    case quit(Int32)
    /// The copy started again as this process.
    case started(Int32)
}

/// How a restart ended.
enum NBBRestartOutcome: Equatable, Sendable {
    /// The new process holds the API.
    case restarted(Int32)
    /// Nothing was quit: the copy's launch couldn't be read, or its program or folder is gone.
    case cantStart
    /// The copy holding the API didn't quit; nothing else was touched.
    case holderStayed
    /// Something else still listens on the API's port; the copy was left alone.
    case portTaken
    /// The copy didn't quit, so it wasn't started again.
    case copyStayed
    /// It didn't start, or its new process exited before taking the API.
    case didntOpen
    /// The new process runs but hasn't taken the API.
    case openedWithoutAPI(Int32)

    /// The new process, once one started.
    var newPID: Int32? {
        switch self {
        case .restarted(let pid), .openedWithoutAPI(let pid): pid
        default: nil
        }
    }

    /// What the page says about it; nothing when it worked. The settings path stays on one line.
    var note: String? {
        switch self {
        case .restarted: nil
        case .cantStart: "sTools can\u{2019}t restart this Ninjabrain Bot because it can\u{2019}t find the program it runs."
        case .holderStayed: "The other Ninjabrain Bot didn\u{2019}t quit, so nothing was restarted."
        case .portTaken: "Something else is using Ninjabrain Bot\u{2019}s API port (52533), so this one wasn\u{2019}t restarted."
        case .copyStayed: "This Ninjabrain Bot didn\u{2019}t quit, so it wasn\u{2019}t restarted."
        case .didntOpen: "Ninjabrain Bot didn\u{2019}t open again. Open it yourself."
        case .openedWithoutAPI: "Ninjabrain Bot opened again without its API. In its Settings\u{00A0}\u{25B8}\u{00A0}Advanced, turn on Enable API (starts HTTP server)."
        }
    }
}

/// Restarts a copy so it takes the API: quits the copy holding it, if one does, then the copy itself, and starts that
/// one again exactly as it was started. Ninjabrain Bot saves its throws to one file for every copy when it quits and
/// reads them back when it opens, so the copy that quits last is the one whose throws come back: the copy itself.
///
/// Nothing is quit before the launch is read and its program found, and the copy isn't quit unless the port came free.
/// Once the copy has quit, it is always started again, whatever happens to the page or the tool meanwhile. Every wait
/// is bounded and sleeps on `clock`; nothing blocks a thread.
enum NBBRestartRun {
    static func run(
        _ copy: NBBCopy, holder: NBBCopy?, restarter: any NBBCopiesRestarting, clock: some Clock<Duration>, timing: NBBRestartTiming,
        step: @Sendable (NBBRestartStep) async -> Void
    ) async -> NBBRestartOutcome {
        let port = LiveNBBCopiesScanner.apiPort
        guard let launch = restarter.launch(of: copy), restarter.canStart(launch) else { return .cantStart }
        if let holder {
            guard await quit(holder, restarter: restarter, clock: clock, timing: timing) else { return .holderStayed }
            await step(.quit(holder.pid))
        }
        guard await wait(until: { !restarter.isListened(on: port) }, for: timing.portGrace, every: timing.look, on: clock) else {
            return .portTaken
        }
        guard await quit(copy, restarter: restarter, clock: clock, timing: timing) else { return .copyStayed }
        await step(.quit(copy.pid))
        guard let pid = restarter.start(launch) else { return .didntOpen }
        await step(.started(pid))
        _ = await wait(
            until: { restarter.listens(pid, on: port) || !restarter.isRunning(pid, startedAt: nil) },
            for: timing.apiGrace, every: timing.look, on: clock)
        if restarter.listens(pid, on: port) { return .restarted(pid) }
        return restarter.isRunning(pid, startedAt: nil) ? .openedWithoutAPI(pid) : .didntOpen
    }

    /// Asks `copy` to quit, then signals it if it's still there after `quitGrace`. Whether it quit.
    private static func quit(
        _ copy: NBBCopy, restarter: any NBBCopiesRestarting, clock: some Clock<Duration>, timing: NBBRestartTiming
    ) async -> Bool {
        let quit = { !restarter.isRunning(copy.pid, startedAt: copy.startedAt) }
        if quit() { return true }
        if await restarter.askToQuit(copy), await wait(until: quit, for: timing.quitGrace, every: timing.look, on: clock) {
            return true
        }
        restarter.signalToQuit(copy)
        return await wait(until: quit, for: timing.signalGrace, every: timing.look, on: clock)
    }

    /// Looks every `interval` until `condition` holds or `limit` has passed. Whether it held.
    static func wait(until condition: () -> Bool, for limit: Duration, every interval: Duration, on clock: some Clock<Duration>) async -> Bool {
        let deadline = clock.now.advanced(by: limit)
        while !condition() {
            guard clock.now < deadline else { return false }
            do {
                try await clock.sleep(until: min(clock.now.advanced(by: interval), deadline), tolerance: nil)
            } catch {
                return condition()
            }
        }
        return true
    }
}

/// Restarts copies for real: reads their launch from the process table, asks them to quit through AppKit and starts them
/// again with `posix_spawn`.
struct LiveNBBCopiesRestarter: NBBCopiesRestarting {
    func launch(of copy: NBBCopy) -> NBBLaunch? {
        guard isRunning(copy.pid, startedAt: copy.startedAt) else { return nil }
        return LiveNBBCopiesScanner.launch(of: copy.pid)
    }

    func canStart(_ launch: NBBLaunch) -> Bool { Self.canStart(launch) }

    func askToQuit(_ copy: NBBCopy) async -> Bool {
        await MainActor.run { NSRunningApplication(processIdentifier: copy.pid)?.terminate() ?? false }
    }

    func signalToQuit(_ copy: NBBCopy) {
        // Never a process that took the number since.
        guard isRunning(copy.pid, startedAt: copy.startedAt) else { return }
        kill(copy.pid, SIGTERM)
    }

    func isRunning(_ pid: Int32, startedAt: Date?) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return false }
        return startedAt.map { $0 == LiveNBBCopiesScanner.startDate(from: info) } ?? true
    }

    func isListened(on port: UInt16) -> Bool {
        LiveNBBCopiesScanner.listener(on: port, in: LiveProcessTable(), user: getuid()) != nil
    }

    func listens(_ pid: Int32, on port: UInt16) -> Bool { LiveNBBCopiesScanner.listens(pid, on: port) }

    func start(_ launch: NBBLaunch) -> Int32? { Self.start(launch) }

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
