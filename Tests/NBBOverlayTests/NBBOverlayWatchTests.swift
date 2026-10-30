import CoreGraphics
import Foundation
import Testing
@testable import NBBOverlay
@testable import STPlatform

// While the NBB Overlay is on it watches Minecraft's window and the Ninjabrain Bot copies (an observation that re-arms
// itself after each change). Switching the tool off and on again used to leave the old watch running and start another,
// so after n switch-ons every change of Minecraft's window ran n rounds of the same work, for as long as the app lived,
// off or on. Crosshair's watch already ends with the tool and starts once.

private struct Granted: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

/// A made-up game window, far outside every real display.
@MainActor
private func game(pid: Int32) -> MinecraftInstance {
    MinecraftInstance(
        window: MinecraftWindow(windowNumber: UInt32(pid), processID: pid, title: "Minecraft* 1.16.1",
                                frame: CGRect(x: -20_000, y: 20_000, width: 800, height: 600)),
        launchDate: Date(timeIntervalSince1970: TimeInterval(pid)), isFrontmost: true, displayID: 1)
}

/// Waits (bounded, awake time only) for `condition`.
@MainActor
private func settle(_ condition: @MainActor () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + .seconds(5)
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
private struct Rig {
    let source = StaticMinecraftWindowSource(instances: [game(pid: 1)])
    let services: ToolServices
    let controller: NBBOverlayController
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "sTools-nbb-watch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let display = DisplayInfo(
            id: 1, name: "Off screen", frame: CGRect(x: -20_000, y: -20_000, width: 1920, height: 1080),
            bounds: CGRect(x: -20_000, y: 20_000, width: 1920, height: 1080), backingScale: 1,
            pixelSize: CGSize(width: 1920, height: 1080), isMain: true)
        services = ToolServices(
            settings: SettingsStore(directory: directory), displays: DisplayDirectory(screenProvider: { [display] }),
            minecraft: MinecraftLocator(source: source), permissions: PermissionCenter(prober: Granted()))
        services.minecraft.refresh()
        controller = NBBOverlayController(
            services: services, connection: NBBConnection(source: FakeEventSource([])),
            copies: NBBCopiesMonitor(scanner: NoNBBCopiesScanner()))
    }

    /// Minecraft's window changes (another game becomes the one followed), which is what the watch hears.
    func changeMinecraft(to pid: Int32) {
        source.instances = [game(pid: pid)]
        services.minecraft.refresh()
    }

    func remove() {
        controller.setEnabled(false)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite("NBB overlay watching Minecraft", .serialized)
struct NBBOverlayWatchTests {
    @Test func oneChangeIsOneRoundHoweverOftenTheToolWasSwitchedOn() async {
        let rig = Rig()
        defer { rig.remove() }
        for _ in 0..<4 {
            rig.controller.setEnabled(true)
            rig.controller.setEnabled(false)
        }
        rig.controller.setEnabled(true)
        let before = rig.controller.watchRounds

        rig.changeMinecraft(to: 2)
        #expect(await settle { rig.controller.watchRounds > before })
        // Anything else that was going to run has run by now.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 1, "one change of Minecraft is one round, not one per switch-on")

        rig.changeMinecraft(to: 3)
        #expect(await settle { rig.controller.watchRounds > before + 1 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 2)
    }

    @Test func aSwitchedOffToolDoesNotWatchAtAll() async {
        let rig = Rig()
        defer { rig.remove() }
        rig.controller.setEnabled(true)
        rig.controller.setEnabled(false)
        let before = rig.controller.watchRounds

        rig.changeMinecraft(to: 2)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before, "off: nothing is watched, and nothing starts the watch again")

        // Switched on again, it watches once, from then on.
        rig.controller.setEnabled(true)
        rig.changeMinecraft(to: 3)
        #expect(await settle { rig.controller.watchRounds > before })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 1)
    }

    /// A tool switched off and on before the watch has heard anything keeps the one watch it has.
    @Test func switchingOffAndOnAgainBeforeAChangeKeepsTheOneWatch() async {
        let rig = Rig()
        defer { rig.remove() }
        rig.controller.setEnabled(true)
        let before = rig.controller.watchRounds
        rig.controller.setEnabled(false)
        rig.controller.setEnabled(true)

        rig.changeMinecraft(to: 2)
        #expect(await settle { rig.controller.watchRounds > before })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.controller.watchRounds == before + 1)
    }
}
