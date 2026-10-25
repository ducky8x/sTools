import AppKit
import Darwin
import Foundation
import Observation

/// One running Ninjabrain Bot: a process whose command line names Ninjabrain (usually `java -jar Ninjabrain-Bot-….jar`),
/// and whether it holds the API's port.
///
/// Ninjabrain Bot always opens its API on port 52533 on every address. A second copy started while another holds the
/// port gets no API at all, and it doesn't try again when the first one quits; only a restart (or turning Enable API off
/// and on in it) gives it the port. So with two copies open, sTools can read only the one that started first.
public struct NBBCopy: Equatable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    /// When the process started, if macOS reported it.
    public var startedAt: Date?
    /// The command that started it, to start it again.
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

/// What sTools sees of Ninjabrain Bot's copies, and what to tell the person.
public enum NBBCopiesSituation: Equatable, Sendable {
    /// No copy, or one copy sharing its data: nothing to say.
    case normal
    /// Several copies; sTools reads the one holding the API. `others` can't share their data.
    case severalOneShares(reading: NBBCopy, others: [NBBCopy])
    /// Copies are open but none holds the API: the one that had it quit, or the API is off in all of them.
    case noneShares(copies: [NBBCopy])

    public init(copies: [NBBCopy]) {
        let sharing = copies.filter(\.holdsAPI)
        if copies.isEmpty {
            self = .normal
        } else if sharing.isEmpty {
            self = .noneShares(copies: copies)
        } else if copies.count == 1 {
            self = .normal
        } else {
            // Ninjabrain Bot's own bind lets only one copy hold the port; should two ever both listen (one per address
            // family), the first started is the one `localhost` reaches.
            let reading = sharing.min { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }!
            self = .severalOneShares(reading: reading, others: copies.filter { $0.pid != reading.pid })
        }
    }

    /// The page's line, or nil when there's nothing to say.
    public var message: String? {
        switch self {
        case .normal:
            nil
        case .severalOneShares(_, let others):
            "\(others.count == 1 ? "Two" : "\(others.count + 1)") Ninjabrain Bots are open. Only the one opened first can share its data, so sTools reads that one. Quit the \(others.count == 1 ? "other" : "others") so you don\u{2019}t mix them up."
        case .noneShares(let copies):
            copies.count == 1
                ? "Ninjabrain Bot is open but isn\u{2019}t sharing its data: it started while another copy had the API, or its API is off. Restart it to let sTools read it."
                : "\(copies.count) Ninjabrain Bots are open but none is sharing its data. Restart one to let sTools read it."
        }
    }

    /// The button beside the line, or nil for none.
    public var actionTitle: String? {
        switch self {
        case .normal: nil
        case .severalOneShares(_, let others): others.count == 1 ? "Quit the Other Copy" : "Quit the Other Copies"
        case .noneShares: "Restart Ninjabrain Bot"
        }
    }
}

/// Lists the running Ninjabrain Bots. The live one reads the process table; tests use a fake.
public protocol NBBCopiesScanning: Sendable {
    func scan() -> [NBBCopy]
}

/// Quits and starts Ninjabrain Bot copies. The live one asks a copy to quit as its Quit menu would, and starts a copy
/// with the command it was started with; tests use a fake.
@MainActor
public protocol NBBCopiesControlling: AnyObject {
    func quit(_ copy: NBBCopy)
    func start(_ arguments: [String]) throws
}

/// Watches Ninjabrain Bot's copies while the NBB Overlay is on (every 2 s; a scan reads only the process table) and
/// offers the fix for the situation it finds.
@MainActor
@Observable
public final class NBBCopiesMonitor {
    public private(set) var copies: [NBBCopy] = []
    public var situation: NBBCopiesSituation { NBBCopiesSituation(copies: copies) }
    /// Whether an action is still waiting for Ninjabrain Bot to quit or start.
    public private(set) var isActing = false
    /// Why the last action couldn't finish, or nil.
    public private(set) var actionError: String?

    @ObservationIgnored private let scanner: any NBBCopiesScanning
    @ObservationIgnored private let control: any NBBCopiesControlling
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let quitWait: Duration
    @ObservationIgnored private var watch: Task<Void, Never>?

    public init(
        scanner: any NBBCopiesScanning = LiveNBBCopiesScanner(),
        control: any NBBCopiesControlling = LiveNBBCopiesControl(),
        interval: Duration = .seconds(2),
        quitWait: Duration = .milliseconds(100)
    ) {
        self.scanner = scanner
        self.control = control
        self.interval = interval
        self.quitWait = quitWait
    }

    public var isWatching: Bool { watch != nil }

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
    }

    /// Runs the situation's fix: quits the copies sTools can't read, or restarts the newest copy so it takes the API.
    public func performAction() async {
        guard !isActing else { return }
        actionError = nil
        switch situation {
        case .normal:
            return
        case .severalOneShares(_, let others):
            isActing = true
            for copy in others { control.quit(copy) }
        case .noneShares(let copies):
            // The newest copy is most likely the window the person is using.
            guard let copy = copies.last else { return }
            isActing = true
            for other in copies { control.quit(other) }
            // Ninjabrain Bot frees the port as it quits; start it again once every copy is gone (5 s at most).
            for _ in 0..<50 where !scanner.scan().isEmpty {
                try? await Task.sleep(for: quitWait)
            }
            do {
                try control.start(copy.arguments)
            } catch {
                actionError = "Ninjabrain Bot couldn\u{2019}t be started again. Open it yourself."
            }
        }
        refresh()
        isActing = false
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

/// Quits a copy the way its Quit menu would (falling back to a polite terminate signal), and starts a copy with the
/// command it was started with.
@MainActor
public final class LiveNBBCopiesControl: NBBCopiesControlling {
    public init() {}

    public func quit(_ copy: NBBCopy) {
        if let app = NSRunningApplication(processIdentifier: copy.pid), app.terminate() { return }
        kill(copy.pid, SIGTERM)
    }

    public func start(_ arguments: [String]) throws {
        guard let executable = arguments.first else { throw CocoaError(.executableNotLoadable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
