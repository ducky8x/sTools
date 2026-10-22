import Foundation
import STPlatform
import Testing
@testable import TimerOverlay

/// Registers nothing with the system.
@MainActor
private final class SilentRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    func register(_ combo: HotkeyCombo, id: UUID) throws {}
    func unregister(id: UUID) {}
}

/// The Key row says where hotkeys work and which key set the tools follow (spec 6.1), as each tool page's Hotkey row
/// does, from what Home ▸ Hotkeys has set.
@MainActor
@Suite("Timer key row: where hotkeys work")
struct TimerKeyWhereLineTests {
    @Test func theLineFollowsHomesHotkeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sTools-timer-key-where-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // No hotkeys.json: a new install's ⌘1–⌘5, which gives Timer Overlay ⌘2.
        let hotkeys = HotkeyCenter(store: SettingsStore(directory: directory), registrar: SilentRegistrar(),
                                   toolStates: { [:] }, handler: { _ in })
        let status = TimerKeyStatus(hotkeys: hotkeys)
        #expect(status.scope == .sToolsAndMinecraft)
        #expect(status.keySet == .command)
        #expect(TimerKeyRow.whereLine(for: status) == "Hotkeys work in sTools and Minecraft · Key set: ⌘1–⌘5")

        hotkeys.scope = .everywhere
        hotkeys.setOwnHotkey(HotkeyCombo(keyCode: 105, modifiers: []), for: .startTimer)
        #expect(TimerKeyRow.whereLine(for: TimerKeyStatus(hotkeys: hotkeys)) == "Hotkeys work in every app · Key set: Custom")
    }

    /// Without Accessibility sTools can't tell when Minecraft is in front, so the line says hotkeys work only in sTools,
    /// as Home does; Everywhere doesn't need Accessibility.
    @Test func withoutAccessibilityTheLineSaysOnlyInSTools() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sTools-timer-key-where-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hotkeys = HotkeyCenter(store: SettingsStore(directory: directory), registrar: SilentRegistrar(),
                                   toolStates: { [:] }, handler: { _ in })
        let status = TimerKeyStatus(hotkeys: hotkeys, accessibilityGranted: false)
        #expect(!status.accessibilityGranted)
        #expect(TimerKeyRow.whereLine(for: status)
            == "Hotkeys work only in sTools until Accessibility is allowed · Key set: ⌘1–⌘5")
        #expect(TimerKeyRow.whereLine(for: TimerKeyStatus(hotkeys: hotkeys, accessibilityGranted: true))
            == "Hotkeys work in sTools and Minecraft · Key set: ⌘1–⌘5")
        hotkeys.scope = .everywhere
        #expect(TimerKeyRow.whereLine(for: TimerKeyStatus(hotkeys: hotkeys, accessibilityGranted: false))
            == "Hotkeys work in every app · Key set: ⌘1–⌘5")
    }

    /// A status built without saying has an empty list's: no key set gives any tool a key, so `noKey` stays what an
    /// empty Home ▸ Hotkeys gives.
    @Test func anEmptyListIsTheNoneKeySet() {
        #expect(TimerKeyStatus.noKey.keySet == .noKeys)
        #expect(TimerKeyStatus.noKey.scope == .sToolsAndMinecraft)
        #expect(TimerKeyStatus(bindings: [], hotkeysAreOn: false) { _ in nil } == .noKey)
    }
}
