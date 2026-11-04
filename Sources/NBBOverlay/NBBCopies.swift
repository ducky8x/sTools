import AppKit
import Darwin
import Foundation
import Observation

/// One running Ninjabrain Bot: a process whose command line names Ninjabrain (usually `java -jar Ninjabrain-Bot-….jar`),
/// and whether it holds the API's port.
///
/// Ninjabrain Bot always opens its API on port 52533 on every address. A second copy started while another holds the
/// port gets no API at all, and it doesn't try again when the first one quits.
public struct NBBCopy: Equatable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    /// When the process started, if macOS reported it.
    public var startedAt: Date?
    /// The command that started it.
    public var arguments: [String]
    /// Whether it listens on Ninjabrain Bot's API port.
    public var holdsAPI: Bool

    public init(pid: Int32, startedAt: Date?, arguments: [String], holdsAPI: Bool) {
        self.pid = pid
        self.startedAt = startedAt
        self.arguments = arguments
        self.holdsAPI = holdsAPI
    }
}

/// Lists the running Ninjabrain Bots. The live one reads the process table; tests use a fake.
public protocol NBBCopiesScanning: Sendable {
    func scan() -> [NBBCopy]
}

/// Finds no copy: for tests and previews, which must never look at the person's real Ninjabrain Bots.
public struct NoNBBCopiesScanner: NBBCopiesScanning {
    public init() {}
    public func scan() -> [NBBCopy] { [] }
}

/// Quits a Ninjabrain Bot copy, as its Quit menu would; tests use a fake.
@MainActor
public protocol NBBCopiesControlling: AnyObject {
    func quit(_ copy: NBBCopy)
}

/// Where a restart is (`NBBCopiesMonitor.restart(_:)`): the copy, as listed when the restart began, and the process the
/// restart is on, the copy's own and then, once started, its new one.
public struct NBBRestartProgress: Equatable, Sendable {
    public var copy: NBBCopy
    public var pid: Int32
}

/// Watches Ninjabrain Bot's copies while the NBB Overlay is on, for the page's list. The overlay reads the API at
/// localhost, so it reads the copy holding the port; the list shows which one that is, and restarts another copy so it
/// takes the API (`restart(_:)`).
///
/// The process table is scanned on a background task, never on the main actor: every 2 s while a copy is open, every
/// 5 s while none is (the first copy to open takes the API, which the overlay reads without the scan's help, so only a
/// second copy needs finding quickly, and by then one is open). A scan's result reaches the main actor only when it
/// differs from the last one. Nothing is scanned while the tool is off.
@MainActor
@Observable
public final class NBBCopiesMonitor {
    public private(set) var copies: [NBBCopy] = []
    /// The restart under way, if one is.
    public private(set) var restarting: NBBRestartProgress?
    /// What went wrong with the last restart, until the next press in the list or until the restarted copy takes the API.
    public private(set) var note: String?
    /// The new process `note` is about, if one started.
    @ObservationIgnored private var notedPID: Int32?

    @ObservationIgnored private let scanner: any NBBCopiesScanning
    @ObservationIgnored private let control: any NBBCopiesControlling
    @ObservationIgnored private let restarter: any NBBCopiesRestarting
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let timing: NBBRestartTiming
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let idleInterval: Duration
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Counts watches, so a scan that ends after its watch stopped or started over is dropped.
    @ObservationIgnored private var generation = 0
    /// How many scan results reached the main actor. For tests.
    @ObservationIgnored private(set) var publishCount = 0

    /// `interval` while a copy is open, `idleInterval` while none is.
    public convenience init(
        scanner: any NBBCopiesScanning = LiveNBBCopiesScanner(),
        control: any NBBCopiesControlling = LiveNBBCopiesControl(),
        interval: Duration = .seconds(2), idleInterval: Duration = .seconds(5)
    ) {
        self.init(scanner: scanner, control: control, restarter: LiveNBBCopiesRestarter(), interval: interval, idleInterval: idleInterval)
    }

    /// With the restarter and the clock its waits sleep on, which tests make up.
    init(
        scanner: any NBBCopiesScanning, control: any NBBCopiesControlling, restarter: any NBBCopiesRestarting,
        clock: any Clock<Duration> = ContinuousClock(), timing: NBBRestartTiming = NBBRestartTiming(),
        interval: Duration = .seconds(2), idleInterval: Duration = .seconds(5)
    ) {
        self.scanner = scanner
        self.control = control
        self.restarter = restarter
        self.clock = clock
        self.timing = timing
        self.interval = interval
        self.idleInterval = idleInterval
    }

    public var isWatching: Bool { watch != nil }

    /// The copy holding the API, which the overlay reads. Nil when none does, or no copy was found (the API at
    /// localhost is still read then, in case Ninjabrain Bot runs in a way the scan doesn't recognize).
    public var holder: NBBCopy? { copies.first(where: \.holdsAPI) }

    /// Whether the page lists the copies: more than one is open, the one open has no API, a restart is under way, or a
    /// note says how the last one went.
    public var showsCopies: Bool { copies.count > 1 || copies.contains { !$0.holdsAPI } || restarting != nil || note != nil }

    public func isRead(_ copy: NBBCopy) -> Bool { copy.holdsAPI }

    public var isRestarting: Bool { restarting != nil }

    /// Whether `copy`'s row is the one being restarted: the copy itself, or its new process.
    public func isRestarting(_ copy: NBBCopy) -> Bool {
        guard let restarting else { return false }
        return copy.pid == restarting.pid || copy.pid == restarting.copy.pid
    }

    /// The page's rows: every copy, and the one being restarted while neither its old process nor its new one is listed.
    public var listed: [NBBCopy] { Self.listed(copies, restarting: restarting) }

    static func listed(_ copies: [NBBCopy], restarting: NBBRestartProgress?) -> [NBBCopy] {
        guard let restarting, !copies.contains(where: { $0.pid == restarting.pid || $0.pid == restarting.copy.pid }) else { return copies }
        return copies + [restarting.copy]
    }

    /// Starts watching; the first scan runs at once, in the background.
    public func start() {
        guard watch == nil else { return }
        watch = makeWatch()
    }

    /// Stops watching. A restart under way goes on: a copy it quit always starts again.
    public func stop() {
        watch?.cancel()
        watch = nil
        generation += 1
        if !copies.isEmpty { copies = [] }
        dismissNote()
    }

    /// Scans again now rather than at the next interval, while watching.
    public func rescan() {
        guard watch != nil else { return }
        watch?.cancel()
        watch = makeWatch()
    }

    /// Asks a copy to quit, as its Quit menu would, and looks again. Nothing while a restart is under way.
    public func quit(_ copy: NBBCopy) {
        guard restarting == nil else { return }
        dismissNote()
        control.quit(copy)
        rescan()
    }

    /// Restarts `copy` so it takes the API (`NBBRestartRun`): quits the copy holding it, if one does, then `copy`, and
    /// starts `copy` again as it was started. Runs off the main actor and ends on its own, whatever happens to the
    /// monitor meanwhile; the list follows each step. Nothing while another restart is under way, or for a copy that
    /// already holds the API.
    public func restart(_ copy: NBBCopy) {
        guard restarting == nil, watch != nil, copies.contains(copy), !copy.holdsAPI else { return }
        dismissNote()
        let holder = copies.first { $0.holdsAPI }
        restarting = NBBRestartProgress(copy: copy, pid: copy.pid)
        let restarter = restarter, clock = clock, timing = timing
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await NBBRestartRun.run(copy, holder: holder, restarter: restarter, clock: clock, timing: timing) { [weak self] step in
                await self?.restartMoved(step)
            }
            await self?.restartEnded(outcome)
        }
    }

    /// Clears the note, as the next press in the list does.
    public func dismissNote() {
        if note != nil { note = nil }
        notedPID = nil
    }

    private func restartMoved(_ step: NBBRestartStep) {
        if case .started(let pid) = step { restarting?.pid = pid }
        rescan()
    }

    private func restartEnded(_ outcome: NBBRestartOutcome) {
        restarting = nil
        // While the tool is off nothing is listed, so nothing is said.
        if watch != nil, let text = outcome.note {
            note = text
            notedPID = outcome.newPID
        }
        rescan()
    }

    /// Scans on a background task until cancelled, and hands each result that differs from the last to the main actor.
    private func makeWatch() -> Task<Void, Never> {
        generation += 1
        let generation = generation
        let scanner = scanner, interval = interval, idleInterval = idleInterval
        return Task.detached(priority: .utility) { [weak self] in
            var last: [NBBCopy]?
            // Ends with the monitor too, should it go without being stopped.
            while !Task.isCancelled, self != nil {
                let found = Self.ordered(scanner.scan())
                if found != last {
                    last = found
                    await self?.publish(found, generation: generation)
                }
                try? await Task.sleep(for: found.isEmpty ? idleInterval : interval)
            }
        }
    }

    /// Oldest first, so the last copy is the newest.
    private nonisolated static func ordered(_ copies: [NBBCopy]) -> [NBBCopy] {
        copies.sorted { ($0.startedAt ?? .distantPast, $0.pid) < ($1.startedAt ?? .distantPast, $1.pid) }
    }

    private func publish(_ found: [NBBCopy], generation: Int) {
        guard generation == self.generation else { return }
        publishCount += 1
        if found != copies { copies = found }
        // A restarted copy that took the API after all (turned on in its settings) needs no note.
        if let notedPID, found.contains(where: { $0.pid == notedPID && $0.holdsAPI }) { dismissNote() }
    }

    /// The line under the page's list of copies.
    public static let caption = "Only one Ninjabrain Bot can use the API at once, and the overlay reads the one that has it."

    /// How the page names a copy: when it was opened and whether it has the API.
    public static func description(of copy: NBBCopy, now: Date = Date(), calendar: Calendar = .current) -> String {
        let opened = opened(copy, now: now, calendar: calendar).map { "O" + $0.dropFirst() } ?? "Open"
        return opened + (copy.holdsAPI ? " \u{00B7} shares its data" : " \u{00B7} without the API")
    }

    /// When a copy was opened, as a phrase: "opened at 9:12" today, "opened Nov 3 at 9:12" before. Nil when macOS
    /// didn't say.
    static func opened(_ copy: NBBCopy, now: Date, calendar: Calendar) -> String? {
        guard let started = copy.startedAt else { return nil }
        let time = started.formatted(date: .omitted, time: .shortened)
        return calendar.isDate(started, inSameDayAs: now) ? "opened at \(time)" : "opened \(started.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }

    /// The question before Read This One… restarts a copy.
    public static let restartQuestion = "Restart this Ninjabrain Bot?"

    /// What the restart does, with `holder` the copy holding the API now, if one does.
    public static func restartMessage(holder: NBBCopy?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let saved = "Save state between sessions is on in Ninjabrain Bot\u{2019}s settings."
        guard let holder else {
            return "sTools restarts this Ninjabrain Bot so it gets the API. Its throws come back if \(saved)"
        }
        let opened = opened(holder, now: now, calendar: calendar).map { ", \($0)" } ?? ""
        return "sTools quits the other Ninjabrain Bot\(opened), then restarts this one so it gets the API. "
            + "This one\u{2019}s throws come back if \(saved) The other one\u{2019}s aren\u{2019}t kept."
    }
}

// MARK: - Live

/// What the process table says about a process before its command line is read.
struct NBBProcessSummary: Equatable, Sendable {
    /// The user it runs as.
    var uid: uid_t
    /// Its executable's name as the process table's short call gives it: the first 15 bytes.
    var name: String
}

/// The parts of the process table a scan reads. The live one is `libproc` and `sysctl`; tests use a fake.
protocol NBBProcessTable {
    func pids() -> [pid_t]
    /// Nil when the process is gone or can't be read.
    func summary(of pid: pid_t) -> NBBProcessSummary?
    func executablePath(of pid: pid_t) -> String?
    func arguments(of pid: pid_t) -> [String]?
    func startDate(of pid: pid_t) -> Date?
    func listens(_ pid: pid_t, on port: UInt16) -> Bool
}

/// Reads the process table: every process of this user whose command line names Ninjabrain, and whether it listens on
/// port 52533. Uses `sysctl` and `libproc`, which need no permission for one's own processes.
///
/// One short call per process (its user and name) rules out other users' processes, and the executable's path most of
/// the rest: only Java, and executables named after Ninjabrain or kept in a Ninjabrain app bundle, have their command
/// line read, and only Ninjabrain Bots their start and sockets. About 1 ms on a Mac with 1,100 processes; reading every
/// process's command line took about 9 ms.
public struct LiveNBBCopiesScanner: NBBCopiesScanning {
    public static let apiPort: UInt16 = 52533

    public init() {}

    public func scan() -> [NBBCopy] {
        Self.scan(LiveProcessTable(), user: getuid(), excluding: getpid())
    }

    /// The copies in `table` that run as `user`, leaving out the kernel, launchd and `ownPID` (sTools itself).
    static func scan(_ table: some NBBProcessTable, user: uid_t, excluding ownPID: pid_t) -> [NBBCopy] {
        table.pids().compactMap { pid -> NBBCopy? in
            guard pid > 1, pid != ownPID, let process = table.summary(of: pid), process.uid == user,
                  mightBeNinjabrainBot(name: process.name, executablePath: { table.executablePath(of: pid) }),
                  let arguments = table.arguments(of: pid), isNinjabrainBot(arguments) else { return nil }
            return NBBCopy(pid: pid, startedAt: table.startDate(of: pid), arguments: arguments, holdsAPI: table.listens(pid, on: apiPort))
        }
    }

    /// Whether a process may be a Ninjabrain Bot, from its executable alone, before its command line is read: Java
    /// (`java`, `javaw` and the like, whose command line then names the jar), or an executable named after Ninjabrain
    /// or kept in a Ninjabrain app bundle. The path is read only when the name doesn't already say so.
    static func mightBeNinjabrainBot(name: String, executablePath: () -> String?) -> Bool {
        if name.utf8.starts(with: "java".utf8, by: equalIgnoringASCIICase) || contains(name.utf8, "ninjabrain") { return true }
        return executablePath().map { contains($0.utf8, "ninjabrain") } ?? false
    }

    /// Whether `text` contains `word` (lowercase ASCII), ignoring ASCII case: without making a lowercased copy, as the
    /// scan checks the path of most processes.
    private static func contains(_ text: String.UTF8View, _ word: StaticString) -> Bool {
        let word = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
        guard let first = word.first, text.count >= word.count else { return false }
        var index = text.startIndex
        while let start = text[index...].firstIndex(where: { equalIgnoringASCIICase($0, first) }) {
            if text[start...].starts(with: word, by: equalIgnoringASCIICase) { return true }
            index = text.index(after: start)
        }
        return false
    }

    /// `byte` against a lowercase ASCII `lowercase`, ignoring case.
    private static func equalIgnoringASCIICase(_ byte: UInt8, _ lowercase: UInt8) -> Bool {
        byte == lowercase || (byte >= 0x41 && byte <= 0x5A && byte | 0x20 == lowercase)
    }

    /// A Ninjabrain Bot's command line: Java running a Ninjabrain jar, or an app bundle named after it.
    static func isNinjabrainBot(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            let name = (argument as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("ninjabrain") && (name.hasSuffix(".jar") || argument.lowercased().contains("ninjabrain") && argument.contains(".app/"))
        }
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    /// The process's user and executable name, in the process table's shortest call.
    static func summary(of pid: pid_t) -> NBBProcessSummary? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return NBBProcessSummary(uid: info.pbsi_uid, name: name)
    }

    static func executablePath(of pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4 * Int(MAXPATHLEN)) { buffer in
            let length = proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
        }
    }

    /// The process's argv, from `KERN_PROCARGS2`: an argument count, the executable path, then the arguments.
    static func arguments(of pid: pid_t) -> [String]? {
        procArgsBuffer(of: pid).flatMap(parseProcArgs)
    }

    /// The process's `KERN_PROCARGS2` buffer, environment and all.
    static func procArgsBuffer(of pid: pid_t) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Splits a `KERN_PROCARGS2` buffer into argv, leaving the environment unread: what a scan needs.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String]? {
        guard let read = split(buffer, readsEnvironment: false), !read.arguments.isEmpty else { return nil }
        return read.arguments
    }

    /// Splits a `KERN_PROCARGS2` buffer into the executable path, every argument and the environment, for a restart.
    /// Nil unless the buffer holds as many whole arguments as its count says.
    static func parseProcArgs(withEnvironment buffer: [UInt8]) -> NBBProcArgs? {
        guard let read = split(buffer, readsEnvironment: true), read.isWhole else { return nil }
        return NBBProcArgs(executablePath: read.executablePath, arguments: read.arguments, environment: read.environment)
    }

    /// The kernel's layout: the argument count, the executable path, padding, each argument, each environment entry, an
    /// empty string, then strings macOS keeps for the loader (`ptr_munge=` and the like), which aren't the environment.
    private static func split(_ buffer: [UInt8], readsEnvironment: Bool) -> (executablePath: String, arguments: [String], environment: [String], isWhole: Bool)? {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        /// The string from `index` to its terminating zero; whether it had one.
        func string() -> (String, terminated: Bool) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return (String(decoding: buffer[start..<index], as: UTF8.self), index < size)
        }
        let executablePath = string().0
        // The padding after the executable path.
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var isWhole = true
        while arguments.count < Int(argc), index < size {
            let (argument, terminated) = string()
            arguments.append(argument)
            isWhole = isWhole && terminated
        }
        isWhole = isWhole && arguments.count == Int(argc)
        var environment: [String] = []
        while readsEnvironment, index < size, buffer[index] != 0 {
            let (entry, terminated) = string()
            if terminated { environment.append(entry) }
        }
        return (executablePath, arguments, environment, isWhole)
    }

    /// The process's current folder, through `libproc`.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// How the process was started, read only when a restart begins (a scan never reads the environment or the folder).
    /// Nil when anything can't be read, the environment included: macOS hides it for its own programs, and starting
    /// Ninjabrain Bot again without one would change how it runs.
    static func launch(of pid: pid_t) -> NBBLaunch? {
        guard let executablePath = executablePath(of: pid),
              let read = procArgsBuffer(of: pid).flatMap(parseProcArgs(withEnvironment:)), !read.environment.isEmpty,
              let workingDirectory = workingDirectory(of: pid) else { return nil }
        return NBBLaunch(executablePath: executablePath, arguments: read.arguments, environment: read.environment, workingDirectory: workingDirectory)
    }

    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return startDate(from: info)
    }

    static func startDate(from info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// A process of `user` listening on `port`, on any address, if there is one. Other users' sockets can't be read.
    static func listener(on port: UInt16, in table: some NBBProcessTable, user: uid_t) -> pid_t? {
        table.pids().first { pid in pid > 0 && table.summary(of: pid)?.uid == user && table.listens(pid, on: port) }
    }

    /// Whether `pid` has a TCP socket listening on `port`, on any address.
    static func listens(_ pid: pid_t, on port: UInt16) -> Bool {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize else { continue }
            guard socket.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port { return true }
        }
        return false
    }
}

/// The real process table.
struct LiveProcessTable: NBBProcessTable {
    func pids() -> [pid_t] { LiveNBBCopiesScanner.allPIDs() }
    func summary(of pid: pid_t) -> NBBProcessSummary? { LiveNBBCopiesScanner.summary(of: pid) }
    func executablePath(of pid: pid_t) -> String? { LiveNBBCopiesScanner.executablePath(of: pid) }
    func arguments(of pid: pid_t) -> [String]? { LiveNBBCopiesScanner.arguments(of: pid) }
    func startDate(of pid: pid_t) -> Date? { LiveNBBCopiesScanner.startDate(of: pid) }
    func listens(_ pid: pid_t, on port: UInt16) -> Bool { LiveNBBCopiesScanner.listens(pid, on: port) }
}

/// Quits a copy the way its Quit menu would, falling back to a polite terminate signal.
@MainActor
public final class LiveNBBCopiesControl: NBBCopiesControlling {
    public init() {}

    public func quit(_ copy: NBBCopy) {
        if let app = NSRunningApplication(processIdentifier: copy.pid), app.terminate() { return }
        kill(copy.pid, SIGTERM)
    }
}
