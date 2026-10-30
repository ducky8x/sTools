import Foundation
import Testing
@testable import KeyRebinder
@testable import STPlatform

// QA matrix (spec 9.2): Minecraft started by the official launcher and by Prism Launcher. The launchers start the game
// differently, and sTools finds the game's `options.txt` from the way each does it, so these tests start stand-in
// processes the same way (no Minecraft, no launcher) and let the real kernel calls read them back.

/// A stand-in for a running Java: `/bin/sh` blocked on an input nobody writes, so it uses no CPU, started with the
/// arguments and the working directory a launcher gives the game. It is the same user's process, so reading its command
/// line and working directory needs no permission.
private final class StandInJava {
    let process = Process()
    private let input = Pipe()

    /// - Parameters:
    ///   - arguments: what follows `java` on the command line.
    ///   - workingDirectory: where the launcher started it.
    init(arguments: [String], workingDirectory: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `sh -c 'read line' java <arguments>`: sh's own argv becomes ["/bin/sh", "-c", "read line", "java", <arguments>].
        process.arguments = ["-c", "read line", "java"] + arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var processID: Int32 { process.processIdentifier }

    /// Ends it: closing its input ends `read`, and the signal covers a shell that hasn't got there yet.
    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// A folder in the temporary directory, removed when the test lets go of it.
private final class Folder {
    let url: URL

    init(_ name: String) throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "stools-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A file inside it, with parent folders made.
    @discardableResult
    func write(_ text: String, to path: String) throws -> URL {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    var path: String { url.resolvingSymlinksInPath().path }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private func resolved(_ url: URL?) -> String? { url?.resolvingSymlinksInPath().path }

@Suite("Minecraft started by each launcher")
struct MinecraftLauncherProcessTests {
    /// The official launcher passes `--gameDir`, and the game's working directory can be anywhere.
    @Test func theOfficialLauncherNamesTheGameFolderOnTheCommandLine() throws {
        let game = try Folder("minecraft")
        let elsewhere = try Folder("launcher")
        let java = try StandInJava(
            arguments: ["-Xmx2G", "net.minecraft.client.main.Main", "--username", "ducky", "--version", "1.16.1",
                        "--gameDir", game.url.path, "--assetsDir", game.url.appending(path: "assets").path],
            workingDirectory: elsewhere.url)
        defer { java.stop() }
        #expect(resolved(MinecraftGameDirectory.find(processID: java.processID)) == game.path)
    }

    /// Prism Launcher (and MultiMC) start Java inside the instance's folder and hand the game its arguments another way,
    /// so nothing on the command line names the folder: the working directory is the answer.
    @Test func prismStartsTheGameInsideTheInstanceFolder() throws {
        let instance = try Folder("instances/1.16.1/minecraft")
        let java = try StandInJava(
            arguments: ["-Xmx2G", "-Dorg.lwjgl.librarypath=/natives", "-jar", "NewLaunch.jar"],
            workingDirectory: instance.url)
        defer { java.stop() }
        #expect(MinecraftGameDirectory.arguments(processID: java.processID)?.contains("--gameDir") == false)
        #expect(resolved(MinecraftGameDirectory.find(processID: java.processID)) == instance.path)
    }

    /// The command line wins over the working directory when both say something, as the official launcher's does.
    @Test func aGameDirArgumentBeatsTheWorkingDirectory() throws {
        let named = try Folder("named")
        let inside = try Folder("inside")
        let java = try StandInJava(arguments: ["--gameDir=\(named.url.path)"], workingDirectory: inside.url)
        defer { java.stop() }
        #expect(resolved(MinecraftGameDirectory.find(processID: java.processID)) == named.path)
    }

    @Test func aProcessThatIsGoneHasNoGameFolder() throws {
        let folder = try Folder("gone")
        let java = try StandInJava(arguments: [], workingDirectory: folder.url)
        let pid = java.processID
        java.stop()
        // Wait (bounded) for the shell to end and be reaped, so its process id is really free.
        let deadline = SuspendingClock().now + .seconds(10)
        while SuspendingClock().now < deadline, MinecraftGameDirectory.workingDirectory(processID: pid) != nil {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(MinecraftGameDirectory.find(processID: pid) == nil)
    }
}

// MARK: - The Key Rebinder follows the instance sTools follows

private struct EverythingAllowed: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// `karabiner_cli` never runs: every command fails to start, as if Karabiner-Elements weren't installed.
private struct NoKarabiner: CommandRunner {
    func run(_ executable: URL, _ args: [String]) async throws -> CommandResult {
        throw CommandRunnerError.launchFailed("Tests never run karabiner_cli.")
    }
}

@MainActor
private func instance(pid: Int32, version: String, launched: TimeInterval) -> MinecraftInstance {
    MinecraftInstance(
        window: MinecraftWindow(
            windowNumber: UInt32(pid), processID: pid, title: "Minecraft* \(version)",
            frame: CGRect(x: -9000, y: -9000, width: 800, height: 600)),
        launchDate: Date(timeIntervalSince1970: launched))
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + .seconds(10)
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("Key Rebinder and the running launcher", .serialized) @MainActor
struct KeyRebinderLauncherTests {
    private let settingsFolder: Folder
    private let source = StaticMinecraftWindowSource()
    private let controller: KeyRebinderController

    init() throws {
        settingsFolder = try Folder("settings")
        let services = ToolServices(
            settings: SettingsStore(directory: settingsFolder.url.appending(path: "sTools")),
            displays: DisplayDirectory(screenProvider: { [] }),
            minecraft: MinecraftLocator(source: source, coalescing: .milliseconds(5)),
            permissions: PermissionCenter(prober: EverythingAllowed()))
        controller = KeyRebinderController(
            services: services, configURL: settingsFolder.url.appending(path: "karabiner/karabiner.json"),
            backupsDirectory: settingsFolder.url.appending(path: "backups"),
            cli: KarabinerCLI(runner: NoKarabiner(), cliURL: URL(fileURLWithPath: "/fake/karabiner_cli"), fileExists: { _ in true }),
            probes: KarabinerProbes(appBundleExists: { false }, cliVersion: { nil }, configReadable: { false }))
        services.minecraft.start()
    }

    private func stopFollowing() { controller.services.minecraft.stop() }

    /// Both launchers' games running together (the conflict rule): the one sTools follows, the earlier of two on the
    /// preferred version, supplies the keybinds, and when it closes the other's take over.
    @Test func theFollowedGamesOptionsAreRead() async throws {
        defer { stopFollowing() }
        let official = try Folder("official")
        let prism = try Folder("instances/1.16.1/minecraft")
        let officialOptions = try official.write("key_key.hotbar.1:key.keyboard.f6\n", to: "options.txt")
        let prismOptions = try prism.write("key_key.hotbar.1:key.keyboard.f7\n", to: "options.txt")
        let officialJava = try StandInJava(arguments: ["--gameDir", official.url.path], workingDirectory: settingsFolder.url)
        let prismJava = try StandInJava(arguments: ["-jar", "NewLaunch.jar"], workingDirectory: prism.url)
        defer { officialJava.stop(); prismJava.stop() }

        source.instances = [
            instance(pid: officialJava.processID, version: "1.16.1", launched: 100),
            instance(pid: prismJava.processID, version: "1.16.1", launched: 200),
        ]
        #expect(await eventually { resolved(controller.optionsFile) == resolved(officialOptions) })
        #expect(controller.minecraftKeybinds?.contains { $0.action == .hotbar(1) && $0.event == .key("f6") } == true)
        #expect(controller.optionsProblem == nil)

        // The official launcher's game closes: Prism's is the one left.
        source.instances = [instance(pid: prismJava.processID, version: "1.16.1", launched: 200)]
        #expect(await eventually { resolved(controller.optionsFile) == resolved(prismOptions) })
        #expect(controller.minecraftKeybinds?.contains { $0.action == .hotbar(1) && $0.event == .key("f7") } == true)
    }

    /// A game on another version loses to one on 1.16.1 whichever opened first (rule R11), launcher or not.
    @Test func the116InstanceWinsOverAnEarlierOtherVersion() async throws {
        defer { stopFollowing() }
        let newer = try Folder("newer")
        let speedrun = try Folder("instances/speedrun/minecraft")
        try newer.write("key_key.hotbar.1:key.keyboard.f6\n", to: "options.txt")
        let speedrunOptions = try speedrun.write("key_key.hotbar.1:key.keyboard.f7\n", to: "options.txt")
        let newerJava = try StandInJava(arguments: ["--gameDir", newer.url.path], workingDirectory: settingsFolder.url)
        let speedrunJava = try StandInJava(arguments: [], workingDirectory: speedrun.url)
        defer { newerJava.stop(); speedrunJava.stop() }

        source.instances = [
            instance(pid: newerJava.processID, version: "1.20.4", launched: 100),
            instance(pid: speedrunJava.processID, version: "1.16.1", launched: 200),
        ]
        #expect(await eventually { resolved(controller.optionsFile) == resolved(speedrunOptions) })
    }

    /// With no game running, the last folder found stays in use rather than the keybinds vanishing.
    @Test func theLastFoundFileStaysWhenTheGameCloses() async throws {
        defer { stopFollowing() }
        let game = try Folder("game")
        let options = try game.write("key_key.hotbar.1:key.keyboard.f6\n", to: "options.txt")
        let java = try StandInJava(arguments: ["--gameDir", game.url.path], workingDirectory: settingsFolder.url)
        defer { java.stop() }
        source.instances = [instance(pid: java.processID, version: "1.16.1", launched: 100)]
        #expect(await eventually { resolved(controller.optionsFile) == resolved(options) })

        source.instances = []
        #expect(await eventually { controller.services.minecraft.active == nil })
        controller.loadMinecraftKeybinds()
        #expect(resolved(controller.optionsFile) == resolved(options))
        #expect(controller.minecraftKeybinds != nil && controller.optionsProblem == nil)
    }

    /// A game whose folder holds no `options.txt` yet says what to do, not nothing.
    @Test func aGameFolderWithoutOptionsSaysSo() async throws {
        defer { stopFollowing() }
        let empty = try Folder("fresh")
        let java = try StandInJava(arguments: ["--gameDir", empty.url.path], workingDirectory: settingsFolder.url)
        defer { java.stop() }
        source.instances = [instance(pid: java.processID, version: "1.16.1", launched: 100)]
        #expect(await eventually { controller.optionsProblem != nil })
        #expect(controller.minecraftKeybinds == nil && controller.optionsFile == nil)
    }
}
