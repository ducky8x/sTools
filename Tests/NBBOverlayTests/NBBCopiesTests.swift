import Foundation
import Testing
@testable import NBBOverlay

private func copy(_ pid: Int32, at seconds: TimeInterval, sharing: Bool) -> NBBCopy {
    NBBCopy(pid: pid, startedAt: Date(timeIntervalSince1970: seconds), arguments: ["/usr/bin/java", "-jar", "/tmp/Ninjabrain-Bot-1.5.2.jar"], holdsAPI: sharing)
}

final class FakeCopiesScanner: NBBCopiesScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NBBCopy]
    init(_ copies: [NBBCopy]) { stored = copies }
    var copies: [NBBCopy] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func scan() -> [NBBCopy] { copies }
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
    private func monitor(_ copies: [NBBCopy]) -> (NBBCopiesMonitor, FakeCopiesControl) {
        let scanner = FakeCopiesScanner(copies)
        let control = FakeCopiesControl(scanner: scanner)
        let monitor = NBBCopiesMonitor(scanner: scanner, control: control)
        monitor.refresh()
        return (monitor, control)
    }

    @Test func oneSharingCopyIsReadOverTheAPIAndNotListed() {
        let (monitor, _) = monitor([copy(1, at: 10, sharing: true)])
        #expect(monitor.readCopy?.pid == 1)
        #expect(!monitor.readsWindow)
        #expect(!monitor.showsCopies)
    }

    @Test func withNoCopyFoundTheAPIIsRead() {
        let (monitor, _) = monitor([])
        #expect(monitor.readCopy == nil && !monitor.readsWindow && !monitor.showsCopies)
    }

    /// ducky's case: an old copy holds the port, and the newer one opened with the game is the one in use.
    @Test func automaticallyTheNewestCopyIsReadFromItsWindow() {
        let (monitor, _) = monitor([copy(2, at: 20, sharing: false), copy(1, at: 10, sharing: true)])
        #expect(monitor.readCopy?.pid == 2)
        #expect(monitor.readsWindow)
        #expect(monitor.showsCopies)
    }

    @Test func pickingACopyReadsItAndBothStayOpen() {
        let (monitor, control) = monitor([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        monitor.choice = .copy(1)
        #expect(monitor.readCopy?.pid == 1)
        #expect(!monitor.readsWindow, "the copy holding the port is read over the API")
        #expect(monitor.copies.count == 2 && control.quit.isEmpty)
    }

    @Test func aPickedCopyThatQuitsFallsBackToAutomatic() {
        let (monitor, control) = monitor([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        monitor.choice = .copy(1)
        monitor.quit(copy(1, at: 10, sharing: true))
        #expect(control.quit == [1])
        #expect(monitor.choice == .automatic)
        #expect(monitor.readCopy?.pid == 2 && monitor.readsWindow)
    }

    @Test func aLoneCopyWithoutTheAPIIsReadFromItsWindowAndListed() {
        let (monitor, _) = monitor([copy(2, at: 20, sharing: false)])
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

    @Test func stoppingForgetsTheCopies() {
        let scanner = FakeCopiesScanner([copy(1, at: 10, sharing: true), copy(2, at: 20, sharing: false)])
        let monitor = NBBCopiesMonitor(scanner: scanner, control: FakeCopiesControl(scanner: scanner))
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

    /// The live scan reads only the process table; it must never crash.
    @Test func theLiveScanRunsWithoutPermissions() {
        _ = LiveNBBCopiesScanner().scan()
    }
}
