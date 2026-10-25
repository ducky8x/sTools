import AppKit
import Darwin
import Foundation
import Observation

/// One running Ninjabrain Bot: a process whose command line names Ninjabrain (usually `java -jar Ninjabrain-Bot-….jar`),
/// and whether it holds the API's port.
///
/// Ninjabrain Bot always opens its API on port 52533 on every address. A second copy started while another holds the
/// port gets no API at all, and it doesn't try again when the first one quits. Such a copy is read from its window.
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

/// Which Ninjabrain Bot the overlay follows.
public enum NBBCopyChoice: Equatable, Sendable {
    /// The newest copy: most likely the window the person just opened, for instance with Minecraft.
    case automatic
    /// The copy with this process number, for as long as it runs; then back to automatic.
    case copy(Int32)
}

/// Lists the running Ninjabrain Bots. The live one reads the process table; tests use a fake.
public protocol NBBCopiesScanning: Sendable {
    func scan() -> [NBBCopy]
}

/// Finds no copy, so the API at localhost is read and no window ever is: for tests and previews, which must never
/// look at the person's real Ninjabrain Bots.
public struct NoNBBCopiesScanner: NBBCopiesScanning {
    public init() {}
    public func scan() -> [NBBCopy] { [] }
}

/// Quits a Ninjabrain Bot copy, as its Quit menu would; tests use a fake.
@MainActor
public protocol NBBCopiesControlling: AnyObject {
    func quit(_ copy: NBBCopy)
}

/// Watches Ninjabrain Bot's copies while the NBB Overlay is on and says which one the overlay reads. A copy holding the
/// API is read over it; any other copy is read from its window (`NBBWindowReader`), so the person can pick the copy they
/// use while every copy stays open.
///
/// The process table is scanned on a background task, never on the main actor: every 2 s while a copy is open, every
/// 5 s while none is (the first copy to open takes the API, which the overlay reads without the scan's help, so only a
/// second copy needs finding quickly, and by then one is open). A scan's result reaches the main actor only when it
/// differs from the last one. Nothing is scanned while the tool is off.
@MainActor
@Observable
public final class NBBCopiesMonitor {
    public private(set) var copies: [NBBCopy] = []
    public var choice: NBBCopyChoice = .automatic

    @ObservationIgnored private let scanner: any NBBCopiesScanning
    @ObservationIgnored private let control: any NBBCopiesControlling
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let idleInterval: Duration
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Counts watches, so a scan that ends after its watch stopped or started over is dropped.
    @ObservationIgnored private var generation = 0
    /// How many scan results reached the main actor. For tests.
    @ObservationIgnored private(set) var publishCount = 0

    /// `interval` while a copy is open, `idleInterval` while none is.
    public init(
        scanner: any NBBCopiesScanning = LiveNBBCopiesScanner(),
        control: any NBBCopiesControlling = LiveNBBCopiesControl(),
        interval: Duration = .seconds(2), idleInterval: Duration = .seconds(5)
    ) {
        self.scanner = scanner
        self.control = control
        self.interval = interval
        self.idleInterval = idleInterval
    }

    public var isWatching: Bool { watch != nil }

    /// The copy the overlay reads: the chosen one while it runs, else the newest. Nil when no copy was found (the API
    /// at localhost is read then, in case Ninjabrain Bot runs in a way the scan doesn't recognize).
    public var readCopy: NBBCopy? {
        if case .copy(let pid) = choice, let chosen = copies.first(where: { $0.pid == pid }) { return chosen }
        return copies.last
    }

    /// Whether the overlay reads a copy's window instead of the API: the copy it follows doesn't hold the port.
    public var readsWindow: Bool { readCopy.map { !$0.holdsAPI } ?? false }

    /// Whether the page lists the copies: more than one is open, or the one open can only be read from its window.
    public var showsCopies: Bool { copies.count > 1 || readsWindow }

    public func isRead(_ copy: NBBCopy) -> Bool { readCopy?.pid == copy.pid }

    /// Starts watching; the first scan runs at once, in the background.
    public func start() {
        guard watch == nil else { return }
        watch = makeWatch()
    }

    public func stop() {
        watch?.cancel()
        watch = nil
        generation += 1
        if !copies.isEmpty { copies = [] }
    }

    /// Scans again now rather than at the next interval, while watching.
    public func rescan() {
        guard watch != nil else { return }
        watch?.cancel()
        watch = makeWatch()
    }

    /// Asks a copy to quit, as its Quit menu would, and looks again.
    public func quit(_ copy: NBBCopy) {
        control.quit(copy)
        rescan()
    }

    /// Scans on a background task until cancelled, and hands each result that differs from the last to the main actor.
    private func makeWatch() -> Task<Void, Never> {
        generation += 1
        let generation = generation
        let scanner = scanner, interval = interval, idleInterval = idleInterval
        return Task.detached(priority: .utility) { [weak self] in
            var last: [NBBCopy]?
            while !Task.isCancelled {
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
        if case .copy(let pid) = choice, !found.contains(where: { $0.pid == pid }) { choice = .automatic }
    }

    /// How the page names a copy: when it was opened and how sTools reads it.
    public static func description(of copy: NBBCopy, now: Date = Date(), calendar: Calendar = .current) -> String {
        let opened: String
        if let started = copy.startedAt {
            let time = started.formatted(date: .omitted, time: .shortened)
            opened = calendar.isDate(started, inSameDayAs: now) ? "Opened at \(time)" : "Opened \(started.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
        } else {
            opened = "Open"
        }
        return opened + (copy.holdsAPI ? " \u{00B7} shares its data" : " \u{00B7} read from its window")
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
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Splits a `KERN_PROCARGS2` buffer into argv.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String]? {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.isEmpty ? nil : arguments
    }

    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
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
