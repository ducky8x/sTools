import Darwin
import Foundation
import Testing
@testable import NBBOverlay

/// A `KERN_PROCARGS2` buffer as the kernel lays it out: the argument count, the executable path and its padding, the
/// arguments, the environment, an empty string, then the strings macOS keeps for the loader.
private func procArgs(executable: String, arguments: [String], environment: [String], padding: Int = 3, loader: Bool = true) -> [UInt8] {
    var buffer: [UInt8] = []
    withUnsafeBytes(of: Int32(arguments.count)) { buffer += $0 }
    buffer += Array(executable.utf8) + [UInt8](repeating: 0, count: padding)
    for string in arguments + environment { buffer += Array(string.utf8) + [0] }
    if loader {
        buffer += [UInt8](repeating: 0, count: 12)
        for string in ["ptr_munge=", "main_stack=", "executable_file=0x1a01000009,0x2c4f1"] { buffer += Array(string.utf8) + [0] }
    }
    return buffer
}

@Suite("Ninjabrain Bot launches")
struct NBBLaunchTests {
    private let java = ["java", "-Xmx1G", "-jar", "/Applications/Ninjabrain Bot/Ninjabrain-Bot-1.5.2.jar"]
    private let environment = ["PATH=/usr/bin:/bin", "HOME=/var/empty", "__CF_USER_TEXT_ENCODING=0x1F5:0x0:0x0"]

    @Test func readsTheArgumentsAndTheEnvironmentFromAProcArgsBuffer() throws {
        let read = try #require(LiveNBBCopiesScanner.parseProcArgs(withEnvironment: procArgs(
            executable: "/opt/java/bin/java", arguments: java, environment: environment)))
        #expect(read.executablePath == "/opt/java/bin/java")
        #expect(read.arguments == java, "argv[0] included, spaces kept")
        #expect(read.environment == environment, "and nothing of the loader's strings after the empty one")
    }

    /// The argument list alone, for the scan, stops before the environment.
    @Test func theScansArgumentsLeaveTheEnvironmentOut() {
        #expect(LiveNBBCopiesScanner.parseProcArgs(procArgs(executable: "/opt/java/bin/java", arguments: java, environment: environment)) == java)
    }

    @Test func anyPaddingAfterTheExecutableIsSkipped() throws {
        for padding in [1, 2, 8] {
            let read = try #require(LiveNBBCopiesScanner.parseProcArgs(withEnvironment: procArgs(
                executable: "/bin/sh", arguments: ["sh", "-c", "true"], environment: ["A=1"], padding: padding)))
            #expect(read.arguments == ["sh", "-c", "true"] && read.environment == ["A=1"])
        }
    }

    @Test func anEnvironmentRunningToTheEndIsReadWhole() throws {
        let read = try #require(LiveNBBCopiesScanner.parseProcArgs(withEnvironment: procArgs(
            executable: "/bin/sh", arguments: ["sh"], environment: ["A=1", "B=2"], loader: false)))
        #expect(read.environment == ["A=1", "B=2"])
    }

    /// macOS hides another process's environment when it's one of its own programs: the arguments are there, the
    /// environment is empty.
    @Test func aHiddenEnvironmentComesBackEmpty() throws {
        let read = try #require(LiveNBBCopiesScanner.parseProcArgs(withEnvironment: procArgs(
            executable: "/bin/sleep", arguments: ["/bin/sleep", "20"], environment: [], loader: false)))
        #expect(read.arguments == ["/bin/sleep", "20"] && read.environment.isEmpty)
    }

    @Test func aShortOrCutBufferReadsAsNothing() {
        #expect(LiveNBBCopiesScanner.parseProcArgs(withEnvironment: [1, 0, 0]) == nil)
        var cut = procArgs(executable: "/bin/sh", arguments: ["sh", "-c", "true"], environment: [], loader: false)
        cut.removeLast(6)
        #expect(LiveNBBCopiesScanner.parseProcArgs(withEnvironment: cut) == nil, "fewer arguments than its count says")
    }

    /// A launch's description never shows the environment, which holds whatever the person's shell had.
    @Test func aLaunchNeverPrintsItsEnvironment() {
        let launch = NBBLaunch(
            executablePath: "/opt/java/bin/java", arguments: java, environment: ["SECRET_TOKEN=hunter2"], workingDirectory: "/tmp")
        for text in [String(describing: launch), String(reflecting: launch), "\(launch)", { var out = ""; dump(launch, to: &out); return out }()] {
            #expect(!text.contains("hunter2") && !text.contains("SECRET_TOKEN"))
        }
        #expect(String(describing: launch).contains("/opt/java/bin/java"))
    }

    // MARK: - Live, on this test process only

    @Test func theLiveTableReadsThisProcessesLaunch() throws {
        let pid = getpid()
        let launch = try #require(LiveNBBCopiesScanner.launch(of: pid))
        #expect(launch.executablePath == LiveNBBCopiesScanner.executablePath(of: pid))
        #expect(launch.arguments == CommandLine.arguments)
        #expect(launch.workingDirectory == URL(filePath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        #expect(!launch.environment.isEmpty && launch.environment.allSatisfy { $0.contains("=") })
        if let home = ProcessInfo.processInfo.environment["HOME"] { #expect(launch.environment.contains("HOME=\(home)")) }
        #expect(LiveNBBCopiesRestarter.canStart(launch))
    }

    @Test func theWorkingDirectoryIsReadThroughLibproc() {
        let folder = LiveNBBCopiesScanner.workingDirectory(of: getpid())
        #expect(folder == URL(filePath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        #expect(LiveNBBCopiesScanner.workingDirectory(of: -1) == nil)
    }

    @Test func aLaunchWhoseProgramOrFolderIsGoneCantStart() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-nbb-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = NBBLaunch(executablePath: "/bin/sh", arguments: ["sh"], environment: ["A=1"], workingDirectory: folder.path)
        #expect(LiveNBBCopiesRestarter.canStart(shell))
        var gone = shell
        gone.executablePath = folder.appending(path: "Ninjabrain-Bot").path
        #expect(!LiveNBBCopiesRestarter.canStart(gone), "no such program")
        gone = shell
        gone.executablePath = folder.path
        #expect(!LiveNBBCopiesRestarter.canStart(gone), "a folder isn't a program")
        gone = shell
        gone.workingDirectory = folder.appending(path: "moved").path
        #expect(!LiveNBBCopiesRestarter.canStart(gone), "no such folder")
    }
}
