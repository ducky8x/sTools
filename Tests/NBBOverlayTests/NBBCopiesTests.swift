import Foundation
import Testing
@testable import NBBOverlay

private func copy(_ pid: Int32, at seconds: TimeInterval, sharing: Bool) -> NBBCopy {
    NBBCopy(pid: pid, startedAt: Date(timeIntervalSince1970: seconds), arguments: ["/usr/bin/java", "-jar", "/tmp/Ninjabrain-Bot-1.5.2.jar"], holdsAPI: sharing)
}

private final class FakeScanner: NBBCopiesScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var _copies: [NBBCopy]
    init(_ copies: [NBBCopy]) { _copies = copies }
    var copies: [NBBCopy] {
        get { lock.withLock { _copies } }
        set { lock.withLock { _copies = newValue } }
    }
    func scan() -> [NBBCopy] { copies }
}

@MainActor
private final class FakeControl: NBBCopiesControlling {
    let scanner: FakeScanner
    var quit: [Int32] = []
    var started: [[String]] = []
    var startFails = false
    init(scanner: FakeScanner) { self.scanner = scanner }
    func quit(_ copy: NBBCopy) {
        quit.append(copy.pid)
        scanner.copies.removeAll { $0.pid == copy.pid }
    }
    func start(_ arguments: [String]) throws {
        if startFails { throw CocoaError(.executableNotLoadable) }
        started.append(arguments)
        scanner.copies.append(copy(999, at: 9_999, sharing: true))
    }
}

@Suite("Ninjabrain Bot copies")
@MainActor
struct NBBCopiesTests {
    @Test func noCopyOrOneSharingCopyNeedsNoNote() {
        #expect(NBBCopiesSituation(copies: []) == .normal)
        #expect(NBBCopiesSituation(copies: [copy(1, at: 10, sharing: true)]) == .normal)
        #expect(NBBCopiesSituation(copies: []).message == nil)
    }

    @Test func twoCopiesReadTheOneThatShares() {
        let first = copy(1, at: 10, sharing: true), second = copy(2, at: 20, sharing: false)
        let situation = NBBCopiesSituation(copies: [second, first])
        #expect(situation == .severalOneShares(reading: first, others: [second]))
        #expect(situation.message?.hasPrefix("Two Ninjabrain Bots are open.") == true)
        #expect(situation.actionTitle == "Quit the Other Copy")
        #expect(NBBCopiesSituation(copies: [first, second, copy(3, at: 30, sharing: false)]).actionTitle == "Quit the Other Copies")
    }

    @Test func aCopyThatIsntSharingOffersARestart() {
        let situation = NBBCopiesSituation(copies: [copy(2, at: 20, sharing: false)])
        #expect(situation == .noneShares(copies: [copy(2, at: 20, sharing: false)]))
        #expect(situation.actionTitle == "Restart Ninjabrain Bot")
        #expect(situation.message?.contains("isn\u{2019}t sharing its data") == true)
    }

    @Test func quittingTheOtherCopiesLeavesTheOneSTREADS() async {
        let scanner = FakeScanner([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        let control = FakeControl(scanner: scanner)
        let monitor = NBBCopiesMonitor(scanner: scanner, control: control, quitWait: .milliseconds(1))
        monitor.refresh()
        await monitor.performAction()
        #expect(control.quit == [2])
        #expect(control.started.isEmpty)
        #expect(monitor.situation == .normal)
        #expect(!monitor.isActing)
    }

    @Test func restartingQuitsEveryCopyThenStartsTheNewestAgain() async {
        let scanner = FakeScanner([copy(1, at: 10, sharing: false), copy(2, at: 20, sharing: false)])
        let control = FakeControl(scanner: scanner)
        let monitor = NBBCopiesMonitor(scanner: scanner, control: control, quitWait: .milliseconds(1))
        monitor.refresh()
        await monitor.performAction()
        #expect(control.quit == [1, 2])
        #expect(control.started == [["/usr/bin/java", "-jar", "/tmp/Ninjabrain-Bot-1.5.2.jar"]])
        #expect(monitor.situation == .normal)
    }

    @Test func aRestartThatCantStartSaysSo() async {
        let scanner = FakeScanner([copy(2, at: 20, sharing: false)])
        let control = FakeControl(scanner: scanner)
        control.startFails = true
        let monitor = NBBCopiesMonitor(scanner: scanner, control: control, quitWait: .milliseconds(1))
        monitor.refresh()
        await monitor.performAction()
        #expect(monitor.actionError == "Ninjabrain Bot couldn\u{2019}t be started again. Open it yourself.")
    }

    @Test func stoppingForgetsTheCopies() {
        let scanner = FakeScanner([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        let monitor = NBBCopiesMonitor(scanner: scanner, control: FakeControl(scanner: scanner))
        monitor.start()
        #expect(monitor.copies.count == 2)
        monitor.stop()
        #expect(monitor.copies.isEmpty && !monitor.isWatching)
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

    /// The live scan reads only the process table; it must find nothing of its own and never crash.
    @Test func theLiveScanRunsWithoutPermissions() {
        _ = LiveNBBCopiesScanner().scan()
    }
}
