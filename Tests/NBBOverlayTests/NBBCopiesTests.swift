import Foundation
import Observation
import Synchronization
import Testing
@testable import NBBOverlay

private func copy(_ pid: Int32, at seconds: TimeInterval, sharing: Bool) -> NBBCopy {
    NBBCopy(pid: pid, startedAt: Date(timeIntervalSince1970: seconds), arguments: ["/usr/bin/java", "-jar", "/tmp/Ninjabrain-Bot-1.5.2.jar"], holdsAPI: sharing)
}

/// Scans made-up copies, counting the scans and whether any ran on the main thread.
final class FakeCopiesScanner: NBBCopiesScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NBBCopy]
    private var scans = 0
    private var scansOnMain = 0
    /// While set, a scan waits (on its background thread) until it's signaled, up to 2 s.
    private var gate: DispatchSemaphore?
    init(_ copies: [NBBCopy]) { stored = copies }
    var copies: [NBBCopy] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var scanCount: Int { lock.withLock { scans } }
    var scanCountOnMainThread: Int { lock.withLock { scansOnMain } }
    func holdScans() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock { gate = semaphore }
        return semaphore
    }
    func scan() -> [NBBCopy] {
        let gate = lock.withLock {
            scans += 1
            if pthread_main_np() != 0 { scansOnMain += 1 }
            return self.gate
        }
        _ = gate?.wait(timeout: .now() + 2)
        return copies
    }
}

/// Waits, without blocking the main actor, until `condition` holds or `seconds` of awake time pass.
@MainActor
func waitUntil(seconds: Double = 2, _ condition: @MainActor () -> Bool) async {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: .seconds(seconds))
    while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
final class FakeCopiesControl: NBBCopiesControlling {
    let scanner: FakeCopiesScanner
    var quit: [Int32] = []
    init(scanner: FakeCopiesScanner) { self.scanner = scanner }
    func quit(_ copy: NBBCopy) {
        quit.append(copy.pid)
        scanner.copies.removeAll { $0.pid == copy.pid }
    }
}

@Suite("Ninjabrain Bot copies")
@MainActor
struct NBBCopiesTests {
    /// A watching monitor of made-up copies, once their first scan has reached it. Stop it at the end of the test.
    private func monitor(_ copies: [NBBCopy]) async -> (NBBCopiesMonitor, FakeCopiesControl) {
        let scanner = FakeCopiesScanner(copies)
        let control = FakeCopiesControl(scanner: scanner)
        let monitor = NBBCopiesMonitor(scanner: scanner, control: control, interval: .milliseconds(10), idleInterval: .milliseconds(10))
        monitor.start()
        await waitUntil { monitor.publishCount > 0 }
        return (monitor, control)
    }

    @Test func oneSharingCopyIsReadOverTheAPIAndNotListed() async {
        let (monitor, _) = await monitor([copy(1, at: 10, sharing: true)])
        defer { monitor.stop() }
        #expect(monitor.readCopy?.pid == 1)
        #expect(!monitor.readsWindow)
        #expect(!monitor.showsCopies)
    }

    @Test func withNoCopyFoundTheAPIIsRead() async {
        let (monitor, _) = await monitor([])
        defer { monitor.stop() }
        #expect(monitor.publishCount == 1)
        #expect(monitor.readCopy == nil && !monitor.readsWindow && !monitor.showsCopies)
    }

    /// ducky's case: an old copy holds the port, and the newer one opened with the game is the one in use.
    @Test func automaticallyTheNewestCopyIsReadFromItsWindow() async {
        let (monitor, _) = await monitor([copy(2, at: 20, sharing: false), copy(1, at: 10, sharing: true)])
        defer { monitor.stop() }
        #expect(monitor.readCopy?.pid == 2)
        #expect(monitor.readsWindow)
        #expect(monitor.showsCopies)
    }

    @Test func pickingACopyReadsItAndBothStayOpen() async {
        let (monitor, control) = await monitor([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        defer { monitor.stop() }
        monitor.choice = .copy(1)
        #expect(monitor.readCopy?.pid == 1)
        #expect(!monitor.readsWindow, "the copy holding the port is read over the API")
        #expect(monitor.copies.count == 2 && control.quit.isEmpty)
    }

    @Test func aPickedCopyThatQuitsFallsBackToAutomatic() async {
        let (monitor, control) = await monitor([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        defer { monitor.stop() }
        monitor.choice = .copy(1)
        monitor.quit(copy(1, at: 10, sharing: true))
        #expect(control.quit == [1])
        await waitUntil { monitor.choice == .automatic }
        #expect(monitor.choice == .automatic)
        #expect(monitor.readCopy?.pid == 2 && monitor.readsWindow)
    }

    @Test func aLoneCopyWithoutTheAPIIsReadFromItsWindowAndListed() async {
        let (monitor, _) = await monitor([copy(2, at: 20, sharing: false)])
        defer { monitor.stop() }
        #expect(monitor.readsWindow && monitor.showsCopies)
    }

    @Test func eachCopySaysWhenItOpenedAndHowItsRead() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_036_000)
        let sharing = NBBCopy(pid: 1, startedAt: now.addingTimeInterval(-60), arguments: [], holdsAPI: true)
        let window = NBBCopy(pid: 2, startedAt: now.addingTimeInterval(-86_400 * 3), arguments: [], holdsAPI: false)
        #expect(NBBCopiesMonitor.description(of: sharing, now: now, calendar: calendar).hasSuffix(" \u{00B7} shares its data"))
        #expect(NBBCopiesMonitor.description(of: sharing, now: now, calendar: calendar).hasPrefix("Opened at "))
        #expect(NBBCopiesMonitor.description(of: window, now: now, calendar: calendar).hasSuffix(" \u{00B7} read from its window"))
        #expect(!NBBCopiesMonitor.description(of: window, now: now, calendar: calendar).hasPrefix("Opened at "))
    }

    @Test func stoppingForgetsTheCopies() async {
        let (monitor, _) = await monitor([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        #expect(monitor.copies.count == 2 && monitor.isWatching)
        monitor.stop()
        #expect(monitor.copies.isEmpty && !monitor.isWatching)
    }

    /// The process table is read on a background task; what it found is set on the main actor.
    @Test func scansRunOffTheMainActorAndResultsArriveOnIt() async {
        let scanner = FakeCopiesScanner([copy(1, at: 10, sharing: true)])
        let monitor = NBBCopiesMonitor(scanner: scanner, control: FakeCopiesControl(scanner: scanner), interval: .milliseconds(10))
        let changedOnMainThread = Mutex<[Bool]>([])
        withObservationTracking { _ = monitor.copies } onChange: {
            changedOnMainThread.withLock { $0.append(pthread_main_np() != 0) }
        }
        monitor.start()
        defer { monitor.stop() }
        await waitUntil { scanner.scanCount >= 3 && monitor.copies.count == 1 }
        #expect(monitor.copies.map(\.pid) == [1])
        #expect(scanner.scanCount >= 3 && scanner.scanCountOnMainThread == 0)
        #expect(changedOnMainThread.withLock { $0 } == [true])
    }

    /// A scan that finds what the last one found doesn't reach the main actor.
    @Test func onlyAChangedResultReachesTheMainActor() async {
        let (monitor, control) = await monitor([copy(1, at: 10, sharing: true)])
        defer { monitor.stop() }
        let scanner = control.scanner
        await waitUntil { scanner.scanCount >= 5 }
        #expect(scanner.scanCount >= 5)
        #expect(monitor.publishCount == 1)
        scanner.copies.append(copy(2, at: 20, sharing: false))
        await waitUntil { monitor.publishCount == 2 }
        #expect(monitor.copies.map(\.pid) == [1, 2])
        let scans = scanner.scanCount
        await waitUntil { scanner.scanCount >= scans + 3 }
        #expect(monitor.publishCount == 2)
    }

    @Test func nothingIsScannedUntilStartedOrAfterStopping() async throws {
        let scanner = FakeCopiesScanner([copy(1, at: 10, sharing: true)])
        let monitor = NBBCopiesMonitor(
            scanner: scanner, control: FakeCopiesControl(scanner: scanner), interval: .milliseconds(10), idleInterval: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(100))
        #expect(scanner.scanCount == 0)
        monitor.start()
        await waitUntil { scanner.scanCount >= 2 }
        monitor.stop()
        // A scan already running when the watch stopped may still end; nothing starts after it.
        try await Task.sleep(for: .milliseconds(30))
        let scans = scanner.scanCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(scanner.scanCount == scans)
        #expect(monitor.copies.isEmpty)
    }

    /// A scan that ends after the tool switched off doesn't bring its copies back.
    @Test func aScanEndingAfterStopIsDropped() async {
        let scanner = FakeCopiesScanner([copy(1, at: 10, sharing: true)])
        let monitor = NBBCopiesMonitor(scanner: scanner, control: FakeCopiesControl(scanner: scanner), interval: .milliseconds(10))
        let gate = scanner.holdScans()
        monitor.start()
        await waitUntil { scanner.scanCount == 1 }
        monitor.stop()
        gate.signal()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(monitor.copies.isEmpty && monitor.publishCount == 0)
    }

    /// A monitor let go of without being stopped takes its watch with it.
    @Test func aMonitorLetGoOfStopsScanning() async throws {
        let scanner = FakeCopiesScanner([copy(1, at: 10, sharing: true)])
        var monitor: NBBCopiesMonitor? = NBBCopiesMonitor(
            scanner: scanner, control: FakeCopiesControl(scanner: scanner), interval: .milliseconds(10))
        monitor?.start()
        await waitUntil { scanner.scanCount >= 2 }
        weak let released = monitor
        monitor = nil
        await waitUntil { released == nil }
        #expect(released == nil)
        try await Task.sleep(for: .milliseconds(30))
        let scans = scanner.scanCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(scanner.scanCount == scans)
    }

    /// While no copy is open the scan waits the longer interval.
    @Test func withNoCopyOpenTheScanWaitsLonger() async throws {
        let scanner = FakeCopiesScanner([])
        let monitor = NBBCopiesMonitor(
            scanner: scanner, control: FakeCopiesControl(scanner: scanner), interval: .milliseconds(10), idleInterval: .seconds(60))
        monitor.start()
        defer { monitor.stop() }
        await waitUntil { monitor.publishCount == 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(scanner.scanCount == 1)
        // A rescan (after a quit, for instance) looks at once; with a copy open, the short interval applies.
        scanner.copies = [copy(1, at: 10, sharing: true)]
        monitor.rescan()
        await waitUntil { scanner.scanCount >= 4 }
        #expect(scanner.scanCount >= 4 && monitor.copies.count == 1)
    }

    @Test(arguments: [
        (["/usr/bin/java", "-jar", "/Users/x/Downloads/Ninjabrain-Bot-1.5.2.jar"], true),
        (["/Applications/Ninjabrain-Bot.app/Contents/MacOS/Ninjabrain-Bot"], true),
        (["/usr/bin/java", "-jar", "/tmp/other.jar"], false),
        (["/usr/bin/grep", "ninjabrain"], false),
    ])
    func recognizesNinjabrainBotsCommandLine(arguments: [String], expected: Bool) {
        #expect(LiveNBBCopiesScanner.isNinjabrainBot(arguments) == expected)
    }

    @Test func readsArgvFromAProcArgsBuffer() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer += $0 }
        buffer += Array("/usr/bin/java".utf8) + [0, 0, 0]
        for argument in ["/usr/bin/java", "-jar", "/tmp/Ninjabrain-Bot.jar"] { buffer += Array(argument.utf8) + [0] }
        buffer += Array("PATH=/usr/bin".utf8) + [0]
        #expect(LiveNBBCopiesScanner.parseProcArgs(buffer) == ["/usr/bin/java", "-jar", "/tmp/Ninjabrain-Bot.jar"])
    }

    /// The live scan reads only the process table; it must never crash.
    @Test func theLiveScanRunsWithoutPermissions() {
        _ = LiveNBBCopiesScanner().scan()
    }

    /// The live table's calls, checked on the test process itself (never on a Ninjabrain Bot): a call that read nothing
    /// would make every scan come back empty.
    @Test func theLiveTableReadsThisProcess() throws {
        let table = LiveProcessTable()
        let pid = getpid()
        #expect(table.pids().contains(pid))
        let summary = try #require(table.summary(of: pid))
        let path = try #require(table.executablePath(of: pid))
        #expect(summary.uid == getuid())
        #expect(summary.name == String((path as NSString).lastPathComponent.utf8.prefix(15))!)
        #expect(table.arguments(of: pid) == CommandLine.arguments)
        let started = try #require(table.startDate(of: pid))
        #expect(started <= Date() && started > Date().addingTimeInterval(-86_400))
        #expect(!LiveNBBCopiesScanner.mightBeNinjabrainBot(name: summary.name, executablePath: { path }))
    }

    @Test(arguments: [
        ("java", nil, true),
        ("javaw", nil, true),
        ("JavaAppLauncher", nil, true),
        ("Ninjabrain-Bot", nil, true),
        ("NINJABRAIN", nil, true),
        ("launcher", "/Applications/Ninjabrain Bot.app/Contents/MacOS/launcher", true),
        ("zsh", "/bin/zsh", false),
        ("grep", "/usr/bin/grep", false),
        ("node", nil, false),
        ("ninja", "/opt/homebrew/bin/ninja", false),
    ] as [(String, String?, Bool)])
    func picksTheProcessesWhoseCommandLineIsRead(name: String, path: String?, expected: Bool) {
        #expect(LiveNBBCopiesScanner.mightBeNinjabrainBot(name: name, executablePath: { path }) == expected)
    }

    @Test func theNameAloneDecidesForJavaAndNinjabrainWithoutReadingThePath() {
        var pathsRead = 0
        for name in ["java", "Ninjabrain-Bot"] {
            #expect(LiveNBBCopiesScanner.mightBeNinjabrainBot(name: name, executablePath: { pathsRead += 1; return nil }))
        }
        #expect(pathsRead == 0)
    }

    /// The scan finds every Ninjabrain Bot of this user, reads the command line only of Java and Ninjabrain-named
    /// executables, and lists sockets only for the copies it found.
    @Test func theScanReadsCommandLinesOnlyOfLikelyProcesses() {
        let jar = "/Users/x/Downloads/Ninjabrain-Bot-1.5.2.jar"
        let table = FakeProcessTable([
            .init(pid: 0, uid: 0, name: "kernel_task", path: nil, arguments: nil),
            .init(pid: 1, uid: 0, name: "launchd", path: "/sbin/launchd", arguments: ["/sbin/launchd"]),
            .init(pid: 50, uid: 501, name: "java", path: "/Library/Java/bin/java", arguments: ["/usr/bin/java", "-jar", jar], listens: true),
            .init(pid: 51, uid: 501, name: "java", path: "/Library/Java/bin/java", arguments: ["/usr/bin/java", "-jar", jar]),
            .init(pid: 52, uid: 501, name: "java", path: "/Library/Java/bin/java", arguments: ["/usr/bin/java", "-jar", "/tmp/other.jar"]),
            .init(pid: 53, uid: 501, name: "JavaLauncher", path: "/System/Library/CoreServices/JavaLauncher.app/Contents/MacOS/JavaLauncher",
                  arguments: ["/System/Library/CoreServices/JavaLauncher.app/Contents/MacOS/JavaLauncher"]),
            .init(pid: 60, uid: 501, name: "Ninjabrain-Bot", path: "/Applications/Ninjabrain-Bot.app/Contents/MacOS/Ninjabrain-Bot",
                  arguments: ["/Applications/Ninjabrain-Bot.app/Contents/MacOS/Ninjabrain-Bot"]),
            .init(pid: 61, uid: 501, name: "launcher", path: "/Applications/Ninjabrain Bot.app/Contents/MacOS/launcher",
                  arguments: ["/Applications/Ninjabrain Bot.app/Contents/MacOS/launcher", "-jar", "/Applications/Ninjabrain Bot.app/Contents/app/Ninjabrain-Bot.jar"]),
            .init(pid: 70, uid: 501, name: "zsh", path: "/bin/zsh", arguments: ["zsh", "-c", "java -jar \(jar)"]),
            .init(pid: 71, uid: 501, name: "grep", path: "/usr/bin/grep", arguments: ["/usr/bin/grep", "ninjabrain"]),
            .init(pid: 80, uid: 502, name: "java", path: "/Library/Java/bin/java", arguments: ["/usr/bin/java", "-jar", jar]),
            .init(pid: 90, uid: 501, name: "java", path: "/Library/Java/bin/java", arguments: ["/usr/bin/java", "-jar", jar]),
        ])
        let copies = LiveNBBCopiesScanner.scan(table, user: 501, excluding: 90)
        #expect(copies.map(\.pid) == [50, 51, 60, 61])
        #expect(copies.map(\.holdsAPI) == [true, false, false, false])
        #expect(copies.allSatisfy { $0.startedAt == Date(timeIntervalSince1970: TimeInterval($0.pid)) })
        #expect(table.summarized == [50, 51, 52, 53, 60, 61, 70, 71, 80], "never the kernel, launchd or sTools itself")
        #expect(table.pathsRead == [61, 70, 71], "only when the name doesn't decide")
        #expect(table.argumentsRead == [50, 51, 52, 53, 60, 61], "never another user's, a shell's or grep's")
        #expect(table.socketsListed == [50, 51, 60, 61])
    }
}

/// A process table made up for a test, which records what a scan read.
final class FakeProcessTable: NBBProcessTable {
    struct Process {
        var pid: pid_t
        var uid: uid_t
        var name: String
        var path: String?
        var arguments: [String]?
        var listens = false
    }

    private let processes: [Process]
    private(set) var summarized: [pid_t] = []
    private(set) var pathsRead: [pid_t] = []
    private(set) var argumentsRead: [pid_t] = []
    private(set) var socketsListed: [pid_t] = []

    init(_ processes: [Process]) { self.processes = processes }

    private func process(_ pid: pid_t) -> Process? { processes.first { $0.pid == pid } }

    func pids() -> [pid_t] { processes.map(\.pid) }

    func summary(of pid: pid_t) -> NBBProcessSummary? {
        summarized.append(pid)
        return process(pid).map { NBBProcessSummary(uid: $0.uid, name: $0.name) }
    }

    func executablePath(of pid: pid_t) -> String? {
        pathsRead.append(pid)
        return process(pid)?.path
    }

    func arguments(of pid: pid_t) -> [String]? {
        argumentsRead.append(pid)
        return process(pid)?.arguments
    }

    func startDate(of pid: pid_t) -> Date? { Date(timeIntervalSince1970: TimeInterval(pid)) }

    func listens(_ pid: pid_t, on port: UInt16) -> Bool {
        socketsListed.append(pid)
        return port == LiveNBBCopiesScanner.apiPort && process(pid)?.listens == true
    }
}
