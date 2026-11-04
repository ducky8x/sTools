import CoreGraphics
import Foundation
import Testing
@testable import NBBOverlay
@testable import STPlatform

private struct NeverPrompting: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// Services on one display far outside every real one, with settings in a temporary folder.
@MainActor
private func offScreenServices(in directory: URL) -> ToolServices {
    let display = DisplayInfo(
        id: 1, name: "Off screen", frame: CGRect(x: -9000, y: -9000, width: 1920, height: 1080),
        bounds: CGRect(x: -9000, y: 9000, width: 1920, height: 1080), backingScale: 1,
        pixelSize: CGSize(width: 1920, height: 1080), isMain: true)
    return ToolServices(
        settings: SettingsStore(directory: directory), displays: DisplayDirectory(screenProvider: { [display] }),
        minecraft: MinecraftLocator(source: StaticMinecraftWindowSource(instances: [])), permissions: PermissionCenter(prober: NeverPrompting()))
}

/// A clock whose sleeps end at once and move its time on, so a restart's waits (seconds of them) take no real time.
final class InstantClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        lock.withLock { current = max(current, deadline) }
        await Task.yield()
    }
}

/// Holds a restart at one step until the test lets it go on.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

/// Made-up processes for a restart: never a real one. Quitting a copy and starting one change what `scanner` finds,
/// as the process table would. Every step is written to `log`, stamped with the clock's time.
final class FakeRestarter: NBBCopiesRestarting, @unchecked Sendable {
    /// How a copy answers being asked to quit.
    enum Quitting { case whenAsked, whenSignaled, never }

    private let lock = NSLock()
    private let scanner: FakeCopiesScanner
    private let clock: InstantClock
    private var quitting: [Int32: Quitting] = [:]
    private var quit: Set<Int32> = []
    private var seenGone: Set<Int32> = []
    private var portSeenFree = false
    private var looksAtNew = 0
    private var entries: [(String, Duration)] = []
    private var started: [NBBLaunch] = []

    /// What `launch(of:)` reads for each copy; a copy missing here can't be read.
    var launches: [Int32: NBBLaunch] = [:]
    var programsExist = true
    /// Something that isn't a listed copy listens on the API's port.
    var portTakenByAnother = false
    var startsAs: Int32? = 900
    /// After how many looks the new process listens on the port; nil for never.
    var newTakesAPIAfter: Int? = 3
    /// After how many looks the new process exits; nil for never.
    var newExitsAfter: Int?
    /// Runs when a copy is asked to quit, before it does.
    var whenAsked: (@Sendable (NBBCopy) async -> Void)?

    init(scanner: FakeCopiesScanner, clock: InstantClock, quitting: [Int32: Quitting] = [:]) {
        self.scanner = scanner
        self.clock = clock
        self.quitting = quitting
    }

    var log: [String] { lock.withLock { entries.map(\.0) } }
    func time(of entry: String) -> Duration? { lock.withLock { entries.first { $0.0 == entry }?.1 } }
    var startedLaunches: [NBBLaunch] { lock.withLock { started } }

    private func note(_ entry: String) { lock.withLock { entries.append((entry, clock.now.offset)) } }

    private func exit(_ pid: Int32) {
        lock.withLock { _ = quit.insert(pid) }
        scanner.copies.removeAll { $0.pid == pid }
    }

    func launch(of copy: NBBCopy) -> NBBLaunch? {
        note("read \(copy.pid)")
        return launches[copy.pid]
    }

    func canStart(_ launch: NBBLaunch) -> Bool { programsExist }

    func askToQuit(_ copy: NBBCopy) async -> Bool {
        note("ask \(copy.pid)")
        await whenAsked?(copy)
        if (lock.withLock { quitting[copy.pid] } ?? .whenAsked) == .whenAsked { exit(copy.pid) }
        return true
    }

    func signalToQuit(_ copy: NBBCopy) {
        note("signal \(copy.pid)")
        if (lock.withLock { quitting[copy.pid] } ?? .whenAsked) == .whenSignaled { exit(copy.pid) }
    }

    func isRunning(_ pid: Int32, startedAt: Date?) -> Bool {
        if pid == startsAs, !startedLaunches.isEmpty {
            let looks = lock.withLock { looksAtNew }
            return newExitsAfter.map { looks < $0 } ?? true
        }
        let running = lock.withLock { !quit.contains(pid) }
        if !running, lock.withLock({ seenGone.insert(pid).inserted }) { note("exited \(pid)") }
        return running
    }

    func isListened(on port: UInt16) -> Bool {
        #expect(port == 52533)
        let taken = portTakenByAnother || scanner.copies.contains { $0.holdsAPI }
        if !taken, lock.withLock({ !portSeenFree }) {
            lock.withLock { portSeenFree = true }
            note("port free")
        }
        return taken
    }

    func listens(_ pid: Int32, on port: UInt16) -> Bool {
        guard pid == startsAs else { return false }
        let looks = lock.withLock { looksAtNew += 1; return looksAtNew }
        let exited = newExitsAfter.map { looks >= $0 } ?? false
        let takes = !exited && newTakesAPIAfter.map { looks >= $0 } ?? false
        if exited { scanner.copies.removeAll { $0.pid == pid } }
        if takes, let index = scanner.copies.firstIndex(where: { $0.pid == pid }), !scanner.copies[index].holdsAPI {
            scanner.copies[index].holdsAPI = true
            note("API \(pid)")
        }
        return takes
    }

    func start(_ launch: NBBLaunch) -> Int32? {
        note("start")
        lock.withLock { started.append(launch) }
        guard let pid = startsAs else { return nil }
        scanner.copies.append(NBBCopy(pid: pid, startedAt: Date(timeIntervalSince1970: 30), arguments: launch.arguments, holdsAPI: false))
        return pid
    }
}

private let holderCopy = NBBCopy(pid: 1, startedAt: Date(timeIntervalSince1970: 10), arguments: ["java", "-jar", "/tmp/Ninjabrain-Bot-1.5.2.jar"], holdsAPI: true)
private let pickedCopy = NBBCopy(pid: 2, startedAt: Date(timeIntervalSince1970: 20), arguments: ["java", "-jar", "/tmp/Ninjabrain-Bot-1.5.2.jar"], holdsAPI: false)
private let pickedLaunch = NBBLaunch(
    executablePath: "/opt/java/bin/java", arguments: ["java", "-jar", "/tmp/Ninjabrain-Bot-1.5.2.jar"],
    environment: ["PATH=/usr/bin:/bin", "STOOLS_TEST=1"], workingDirectory: "/tmp/nbb")

@MainActor
private struct Rig {
    let scanner: FakeCopiesScanner
    let control: FakeCopiesControl
    let clock = InstantClock()
    let restarter: FakeRestarter
    let monitor: NBBCopiesMonitor

    init(_ copies: [NBBCopy] = [holderCopy, pickedCopy], quitting: [Int32: FakeRestarter.Quitting] = [:]) {
        scanner = FakeCopiesScanner(copies)
        control = FakeCopiesControl(scanner: scanner)
        restarter = FakeRestarter(scanner: scanner, clock: clock, quitting: quitting)
        restarter.launches = [2: pickedLaunch]
        monitor = NBBCopiesMonitor(
            scanner: scanner, control: control, restarter: restarter, clock: clock, interval: .milliseconds(10), idleInterval: .milliseconds(10))
    }

    func start() async {
        monitor.start()
        await waitUntil { monitor.copies == scanner.copies }
    }

    /// Restarts the picked copy and waits until the restart is over.
    func restart() async {
        monitor.restart(pickedCopy)
        await waitUntil { !monitor.isRestarting }
    }
}

@Suite("Restarting a Ninjabrain Bot copy")
@MainActor
struct NBBRestartTests {
    /// ducky's case. The other copy goes first, so the picked copy's state is the last one Ninjabrain Bot saves and the
    /// one that comes back; the picked copy starts again exactly as it was started, and takes the API.
    @Test func theHolderQuitsFirstThenThisCopyStartsAgainAsItWas() async {
        let rig = Rig()
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log == ["read 2", "ask 1", "exited 1", "port free", "ask 2", "exited 2", "start", "API 900"])
        #expect(rig.restarter.startedLaunches == [pickedLaunch], "the same program, arguments, environment and folder")
        await waitUntil { rig.monitor.holder?.pid == 900 }
        #expect(rig.monitor.holder?.pid == 900, "the new process holds the API, so it's the one read")
        #expect(rig.monitor.copies.map(\.pid) == [900] && !rig.monitor.showsCopies)
        #expect(rig.monitor.note == nil && !rig.monitor.isRestarting)
        #expect(rig.control.quit.isEmpty, "quitting for a restart never goes through the page's Quit")
    }

    @Test func withoutAHolderOnlyThisCopyQuitsAndStarts() async {
        let rig = Rig([pickedCopy])
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log == ["read 2", "port free", "ask 2", "exited 2", "start", "API 900"])
        #expect(rig.monitor.note == nil)
    }

    /// Asked first, as its Quit menu would; the terminate signal only after a few seconds, which runs Ninjabrain Bot's
    /// shutdown as a quit does. Never the kill signal, which would lose its state.
    @Test func aHolderThatOnlyQuitsOnTheSignalGetsItAfterAFewSeconds() async {
        let rig = Rig(quitting: [1: .whenSignaled])
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log.prefix(4) == ["read 2", "ask 1", "signal 1", "exited 1"])
        #expect(rig.restarter.time(of: "signal 1") == .seconds(3))
        #expect(rig.restarter.log.contains("start") && rig.monitor.note == nil)
    }

    @Test func aHolderThatDoesntQuitLeavesThisCopyAlone() async {
        let rig = Rig(quitting: [1: .never])
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log == ["read 2", "ask 1", "signal 1"])
        #expect(rig.clock.now.offset == .seconds(8), "three seconds after asking, five after the signal")
        #expect(rig.monitor.note == "The other Ninjabrain Bot didn\u{2019}t quit, so nothing was restarted.")
        #expect(rig.monitor.copies.map(\.pid) == [1, 2])
    }

    @Test func aPortSomethingElseHoldsLeavesThisCopyAlone() async {
        let rig = Rig()
        rig.restarter.portTakenByAnother = true
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log == ["read 2", "ask 1", "exited 1"])
        #expect(rig.monitor.note == "Something else is using Ninjabrain Bot\u{2019}s API port (52533), so this one wasn\u{2019}t restarted.")
        await waitUntil { rig.monitor.copies.map(\.pid) == [2] }
        #expect(rig.monitor.copies.map(\.pid) == [2], "this copy still runs")
    }

    @Test func aLaunchThatCantBeReadQuitsNothing() async {
        let rig = Rig()
        rig.restarter.launches = [:]
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log == ["read 2"])
        #expect(rig.monitor.note == "sTools can\u{2019}t restart this Ninjabrain Bot because it can\u{2019}t find the program it runs.")
    }

    @Test func aProgramThatIsGoneQuitsNothing() async {
        let rig = Rig()
        rig.restarter.programsExist = false
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log == ["read 2"])
        #expect(rig.monitor.note == "sTools can\u{2019}t restart this Ninjabrain Bot because it can\u{2019}t find the program it runs.")
    }

    @Test func aCopyThatDoesntQuitIsntRestarted() async {
        let rig = Rig(quitting: [2: .never])
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log == ["read 2", "ask 1", "exited 1", "port free", "ask 2", "signal 2"])
        #expect(rig.monitor.note == "This Ninjabrain Bot didn\u{2019}t quit, so it wasn\u{2019}t restarted.")
    }

    @Test func aStartThatFailsSaysToOpenItByHand() async {
        let rig = Rig()
        rig.restarter.startsAs = nil
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.restarter.log.last == "start")
        #expect(rig.monitor.note == "Ninjabrain Bot didn\u{2019}t open again. Open it yourself.")
    }

    @Test func aNewCopyThatExitsSaysItDidntOpen() async {
        let rig = Rig()
        rig.restarter.newTakesAPIAfter = nil
        rig.restarter.newExitsAfter = 4
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.monitor.note == "Ninjabrain Bot didn\u{2019}t open again. Open it yourself.")
        #expect(rig.clock.now.offset < .seconds(20), "said as soon as it's gone")
    }

    /// Java takes a while to start, so the new copy has about 20 s to take the API. Once it takes it (its API turned on
    /// in its settings), the note goes.
    @Test func aNewCopyWithoutTheAPISaysHowToTurnItOn() async {
        let rig = Rig()
        rig.restarter.newTakesAPIAfter = nil
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.clock.now.offset >= .seconds(20))
        #expect(rig.monitor.note == "Ninjabrain Bot opened again without its API. In its Settings\u{00A0}\u{25B8}\u{00A0}Advanced, turn on Enable API (starts HTTP server).")
        await waitUntil { rig.monitor.copies.map(\.pid) == [900] }
        #expect(rig.monitor.showsCopies, "the note keeps the list up, with the new copy in it")
        rig.restarter.newTakesAPIAfter = 0
        _ = rig.restarter.listens(900, on: 52533)
        await waitUntil { rig.monitor.note == nil }
        #expect(rig.monitor.note == nil && rig.monitor.holder?.pid == 900)
    }

    /// Once this copy has quit it always starts again, whatever happens to the page: switching the tool off doesn't
    /// leave the person without their Ninjabrain Bot.
    @Test func stoppingAfterThisCopyQuitStillStartsIt() async {
        let rig = Rig()
        let monitor = rig.monitor
        rig.restarter.whenAsked = { copy in
            if copy.pid == 2 { await MainActor.run { monitor.stop() } }
        }
        await rig.start()
        monitor.restart(pickedCopy)
        await waitUntil { !monitor.isRestarting }
        #expect(rig.restarter.startedLaunches == [pickedLaunch])
        #expect(!monitor.isWatching && monitor.copies.isEmpty)
        #expect(monitor.note == nil && !monitor.showsCopies, "nothing is shown while the tool is off")
    }

    /// The tool switched off: the same, through the controller. Meanwhile the page doesn't say Ninjabrain Bot stopped
    /// answering, since the restart quit it on purpose.
    @Test func switchingTheToolOffAfterThisCopyQuitStillStartsIt() async throws {
        let rig = Rig()
        let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-nbb-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = NBBOverlayController(
            services: offScreenServices(in: directory), connection: NBBConnection(source: FakeEventSource([])), copies: rig.monitor)
        let gate = Gate()
        rig.restarter.whenAsked = { copy in
            await gate.wait()
            if copy.pid == 2 { await MainActor.run { controller.setEnabled(false) } }
        }
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        await waitUntil { rig.monitor.copies == rig.scanner.copies }
        #expect(controller.saysNotAnswering, "nothing answers at localhost")
        rig.monitor.restart(pickedCopy)
        #expect(!controller.saysNotAnswering)
        await gate.open()
        await waitUntil { !rig.monitor.isRestarting }
        #expect(rig.restarter.startedLaunches == [pickedLaunch])
        #expect(!controller.isEnabled && !controller.saysNotAnswering)
    }

    @Test func aMonitorLetGoOfAfterThisCopyQuitStillStartsIt() async {
        let rig = Rig()
        let restarter = rig.restarter
        let gate = Gate()
        restarter.whenAsked = { copy in if copy.pid == 2 { await gate.wait() } }
        await rig.start()
        rig.monitor.restart(pickedCopy)
        await waitUntil { restarter.log.contains("ask 2") }
        weak let released = rig.monitor
        rig.monitor.stop()
        // The rig, and with it the last reference to the monitor, ends here.
        _ = consume rig
        await gate.open()
        await waitUntil { restarter.log.contains("start") }
        #expect(restarter.startedLaunches == [pickedLaunch])
        #expect(released == nil)
    }

    @Test func whileRestartingEveryOtherPressWaitsAndASecondOneDoesNothing() async {
        let rig = Rig()
        let gate = Gate()
        rig.restarter.whenAsked = { _ in await gate.wait() }
        defer { rig.monitor.stop() }
        await rig.start()
        rig.monitor.restart(pickedCopy)
        #expect(rig.monitor.isRestarting && rig.monitor.isRestarting(pickedCopy) && !rig.monitor.isRestarting(holderCopy))
        await waitUntil { rig.restarter.log.contains("ask 1") }
        rig.monitor.restart(pickedCopy)
        rig.monitor.quit(holderCopy)
        rig.monitor.quit(pickedCopy)
        #expect(rig.control.quit.isEmpty)
        await gate.open()
        await waitUntil { !rig.monitor.isRestarting }
        #expect(rig.restarter.log.filter { $0 == "read 2" }.count == 1)
        #expect(rig.restarter.startedLaunches.count == 1)
    }

    @Test func aNoteGoesWithTheNextPressInTheList() async {
        let rig = Rig()
        rig.restarter.portTakenByAnother = true
        defer { rig.monitor.stop() }
        await rig.start()
        await rig.restart()
        #expect(rig.monitor.note != nil && rig.monitor.showsCopies)
        rig.monitor.dismissNote()
        #expect(rig.monitor.note == nil)

        rig.restarter.launches = [:]
        await rig.restart()
        #expect(rig.monitor.note != nil)
        rig.monitor.quit(pickedCopy)
        #expect(rig.monitor.note == nil, "Quit is a press in the list too")
    }

    /// The copy being restarted keeps its row while it's between processes: the old one gone, the new one not found yet.
    @Test func theRestartingCopyKeepsItsRowBetweenProcesses() {
        let other = NBBCopy(pid: 3, startedAt: Date(timeIntervalSince1970: 5), arguments: [], holdsAPI: false)
        let between = NBBRestartProgress(copy: pickedCopy, pid: 900)
        #expect(NBBCopiesMonitor.listed([other], restarting: between).map(\.pid) == [3, 2])
        #expect(NBBCopiesMonitor.listed([other, pickedCopy], restarting: between).map(\.pid) == [3, 2], "still listed")
        let new = NBBCopy(pid: 900, startedAt: Date(timeIntervalSince1970: 30), arguments: [], holdsAPI: false)
        #expect(NBBCopiesMonitor.listed([other, new], restarting: between).map(\.pid) == [3, 900], "found again")
        #expect(NBBCopiesMonitor.listed([other], restarting: nil).map(\.pid) == [3])
    }

    /// The live restarter's checks, on this test process and a socket of its own, never on a Ninjabrain Bot.
    @Test func theLiveRestarterSeesThisProcessAndItsListeningSocket() async throws {
        let restarter = LiveNBBCopiesRestarter()
        let started = LiveNBBCopiesScanner.startDate(of: getpid())
        #expect(restarter.isRunning(getpid(), startedAt: started))
        #expect(restarter.isRunning(getpid(), startedAt: nil))
        #expect(!restarter.isRunning(getpid(), startedAt: started?.addingTimeInterval(-1)), "another process under the same number")
        #expect(!restarter.isRunning(-1, startedAt: nil))
        let server = try LocalSSEServer()
        #expect(restarter.isListened(on: server.port))
        #expect(restarter.listens(getpid(), on: server.port))
        server.stop()
        await waitUntil { !restarter.isListened(on: server.port) }
        #expect(!restarter.isListened(on: server.port))
    }
}
