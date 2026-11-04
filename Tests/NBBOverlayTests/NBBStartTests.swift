import Darwin
import Foundation
import Testing
@testable import NBBOverlay

/// A temporary folder, by its real path (`/private/var/…`), as the kernel reports a process's folder.
private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-nbb-start-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let real = try #require(realpath(folder.path, nil))
    defer { free(real) }
    return URL(filePath: String(cString: real), directoryHint: .isDirectory)
}

/// Kills `pid`'s whole process group (a started process leads its own session and group) and waits until the reaper has
/// collected it, so no test leaves a process or a zombie behind.
@MainActor
private func killAndReap(_ pid: pid_t) async {
    kill(-pid, SIGKILL)
    kill(pid, SIGKILL)
    await waitUntil { !NBBChildReaper.shared.isWatching(pid) }
}

/// Whether nothing at all has `pid`, not even a zombie waiting to be collected.
private func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

/// The live start, on a harmless `/bin/sh` in a temporary folder: never a Ninjabrain Bot.
@Suite("Starting a Ninjabrain Bot again", .serialized)
@MainActor
struct NBBStartTests {
    @Test func theNewProcessGetsTheSameLaunchInASessionOfItsOwn() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A descriptor open in this process without close-on-exec, which the new process must not get.
        var pipeEnds: [Int32] = [-1, -1]
        try #require(pipe(&pipeEnds) == 0)
        defer { pipeEnds.forEach { close($0) } }
        let script = """
            if [ -c /dev/fd/1 ] && [ -c /dev/fd/2 ]; then out=devices; else out=other; fi
            if read -r line; then input=some; else input=none; fi
            if (: <&\(pipeEnds[0])) 2>/dev/null; then inherited=open; else inherited=closed; fi
            printf '%s\\n' "$0" "$1" "$STOOLS_RESTART_TEST" "$(pwd -P)" "$out" "$input" "$inherited" > report.tmp
            mv report.tmp report.txt
            while :; do /bin/sleep 0.1; done
            """
        let launch = NBBLaunch(
            executablePath: "/bin/sh", arguments: ["stools-test-shell", "-c", script, "first argument", "second"],
            environment: ["STOOLS_RESTART_TEST=a value, with spaces", "PATH=/usr/bin:/bin"], workingDirectory: folder.path)
        let pid = try #require(LiveNBBCopiesRestarter.start(launch))
        let report = folder.appending(path: "report.txt")
        await waitUntil { FileManager.default.fileExists(atPath: report.path) }
        let lines = try String(contentsOf: report, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.prefix(7) == ["first argument", "second", "a value, with spaces", folder.path, "devices", "none", "closed"][...])
        #expect(LiveNBBCopiesScanner.arguments(of: pid) == launch.arguments, "argv[0] included")
        #expect(getsid(pid) == pid, "it leads a session of its own")
        #expect(NBBChildReaper.shared.isWatching(pid))
        await killAndReap(pid)
        #expect(!NBBChildReaper.shared.isWatching(pid))
        #expect(isGone(pid), "collected, not left a zombie")
        #expect(kill(-pid, 0) == -1, "nothing of its group is left")
    }

    /// A process that's done at once is collected too, even if it ended before its exit source was armed.
    @Test func aProcessThatEndsAtOnceIsCollected() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for _ in 0..<5 {
            let launch = NBBLaunch(executablePath: "/usr/bin/true", arguments: ["true"], environment: ["A=1"], workingDirectory: folder.path)
            let pid = try #require(LiveNBBCopiesRestarter.start(launch))
            await waitUntil { !NBBChildReaper.shared.isWatching(pid) }
            #expect(!NBBChildReaper.shared.isWatching(pid))
            #expect(isGone(pid))
        }
    }

    @Test func aProgramThatIsGoneDoesntStart() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = NBBLaunch(
            executablePath: folder.appending(path: "Ninjabrain-Bot").path, arguments: ["Ninjabrain-Bot"], environment: ["A=1"],
            workingDirectory: folder.path)
        #expect(LiveNBBCopiesRestarter.start(missing) == nil)
        let noFolder = NBBLaunch(
            executablePath: "/usr/bin/true", arguments: ["true"], environment: ["A=1"], workingDirectory: folder.appending(path: "gone").path)
        #expect(LiveNBBCopiesRestarter.start(noFolder) == nil)
    }
}
