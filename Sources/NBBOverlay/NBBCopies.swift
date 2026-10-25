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

/// Watches Ninjabrain Bot's copies while the NBB Overlay is on (every 2 s; a scan reads only the process table) and
/// says which one the overlay reads. A copy holding the API is read over it; any other copy is read from its window
/// (`NBBWindowReader`), so the person can pick the copy they use while every copy stays open.
@MainActor
@Observable
public final class NBBCopiesMonitor {
    public private(set) var copies: [NBBCopy] = []
    public var choice: NBBCopyChoice = .automatic

    @ObservationIgnored private let scanner: any NBBCopiesScanning
    @ObservationIgnored private let control: any NBBCopiesControlling
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var watch: Task<Void, Never>?

    public init(
        scanner: any NBBCopiesScanning = LiveNBBCopiesScanner(),
        control: any NBBCopiesControlling = LiveNBBCopiesControl(),
        interval: Duration = .seconds(2)
    ) {
        self.scanner = scanner
        self.control = control
        self.interval = interval
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

    public func start() {
        guard watch == nil else { return }
        refresh()
        watch = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public func stop() {
        watch?.cancel()
        watch = nil
        if !copies.isEmpty { copies = [] }
    }

    /// Scans now. A scan reads only the process table and takes well under a millisecond.
    public func refresh() {
        let found = scanner.scan().sorted { ($0.startedAt ?? .distantPast, $0.pid) < ($1.startedAt ?? .distantPast, $1.pid) }
        if found != copies { copies = found }
        if case .copy(let pid) = choice, !found.contains(where: { $0.pid == pid }) { choice = .automatic }
    }

    /// Asks a copy to quit, as its Quit menu would.
    public func quit(_ copy: NBBCopy) {
        control.quit(copy)
        refresh()
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

/// Reads the process table: every process of this user whose command line names Ninjabrain, and whether it listens on
/// port 52533. Uses `sysctl` and `libproc`, which need no permission for one's own processes.
public struct LiveNBBCopiesScanner: NBBCopiesScanning {
    public static let apiPort: UInt16 = 52533

    public init() {}

    public func scan() -> [NBBCopy] {
        Self.allPIDs().compactMap { pid -> NBBCopy? in
            guard pid > 0, pid != getpid(), let arguments = Self.arguments(of: pid), Self.isNinjabrainBot(arguments) else { return nil }
            return NBBCopy(pid: pid, startedAt: Self.startDate(of: pid), arguments: arguments, holdsAPI: Self.listens(pid, on: Self.apiPort))
        }
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

/// Quits a copy the way its Quit menu would, falling back to a polite terminate signal.
@MainActor
public final class LiveNBBCopiesControl: NBBCopiesControlling {
    public init() {}

    public func quit(_ copy: NBBCopy) {
        if let app = NSRunningApplication(processIdentifier: copy.pid), app.terminate() { return }
        kill(copy.pid, SIGTERM)
    }
}
