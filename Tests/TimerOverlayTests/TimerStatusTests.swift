import Foundation
import STPlatform
import Testing
@testable import TimerOverlay

/// A registrar that registers nothing with the system and refuses the combinations it's told to.
@MainActor
private final class RefusingRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    var refused: Set<HotkeyCombo> = []

    struct Refusal: Error {}

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        if refused.contains(combo) { throw Refusal() }
    }

    func unregister(id: UUID) {}
}

private let f13 = HotkeyCombo(keyCode: 105, modifiers: [])
private let f14 = HotkeyCombo(keyCode: 107, modifiers: [])
private let shiftCommand2 = HotkeyCombo(keyCode: 19, modifiers: [.shift, .command])

@Suite("Timer status")
struct TimerStatusTests {
    @Test func theWordsForEachState() {
        #expect(TimerStatus.off.text == "Off")
        #expect(TimerStatus.ready.text == "Ready")
        #expect(TimerStatus.counting(secondsLeft: 134).text == "2:14 left")
        #expect(TimerStatus.counting(secondsLeft: 5).text == "0:05 left")
        #expect(TimerStatus.paused(secondsLeft: 62).text == "Paused, 1:02")
        #expect(TimerStatus.paused(secondsLeft: 359_999).text == "Paused, 99:59:59", "the longest status")
        #expect(TimerStatus.timesUp.text == "Time\u{2019}s up")
    }

    @Test func theDockBadgeShowsTheTimeLeftOnlyWhileARunIsUnderWay() {
        #expect(TimerStatus.off.badgeText == nil && TimerStatus.ready.badgeText == nil)
        #expect(TimerStatus.counting(secondsLeft: 134).badgeText == "2:14")
        #expect(TimerStatus.paused(secondsLeft: 3_723).badgeText == "1:02:03")
        #expect(TimerStatus.timesUp.badgeText == "0:00")
    }
}

@MainActor
@Suite("Timer key status")
struct TimerKeyStatusTests {
    @Test func noHotkeyIsNoKeyYet() {
        #expect(TimerKeyStatus.noKey.title == "No key yet")
        #expect(!TimerKeyStatus.noKey.hasKey && !TimerKeyStatus.noKey.hotkeysAreOn)
        let others = [HotkeyBinding(combo: f13, actions: [.toggle(.crosshair)])]
        let status = TimerKeyStatus(bindings: others, hotkeysAreOn: true) { _ in .registered }
        #expect(status.title == "No key yet" && status.hotkeysAreOn)
    }

    @Test func itListsEveryStartTimerHotkeyInOrderWithItsProblem() {
        let first = HotkeyBinding(combo: f13, actions: [.startTimer])
        let other = HotkeyBinding(combo: f14, actions: [.toggle(.nbbOverlay)])
        let refused = HotkeyBinding(combo: shiftCommand2, actions: [.toggle(.crosshair), .startTimer])
        let status = TimerKeyStatus(bindings: [first, other, refused], hotkeysAreOn: true) { id in
            id == refused.id ? .conflict(.systemRefused) : .registered
        }
        #expect(status.keys.map(\.id) == [first.id, refused.id])
        #expect(status.keys.map(\.name) == [f13.displayString, shiftCommand2.displayString])
        #expect(status.keys.map(\.problem) == [nil, "Refused by macOS"])
        #expect(status.title == "Start timer: \(f13.displayString) or \(shiftCommand2.displayString)")
        let three = TimerKeyStatus(keys: [
            .init(id: UUID(), name: "F13"), .init(id: UUID(), name: "F14"), .init(id: UUID(), name: "F15"),
        ])
        #expect(three.title == "Start timer: F13, F14 or F15")
    }

    @Test func itReadsHomesHotkeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sTools-timer-key-status-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = RefusingRegistrar()
        registrar.refused = [f14]
        let hotkeys = HotkeyCenter(store: SettingsStore(directory: directory), registrar: registrar,
                                   toolStates: { [:] }, handler: { _ in })
        #expect(TimerKeyStatus(hotkeys: hotkeys) == .noKey)
        let first = hotkeys.add(combo: f13, actions: [.startTimer])
        let second = hotkeys.add(combo: f14, actions: [.startTimer])
        hotkeys.isEnabled = true
        let status = TimerKeyStatus(hotkeys: hotkeys)
        #expect(status.hotkeysAreOn)
        #expect(status.keys.map(\.id) == [first, second])
        #expect(status.keys.map(\.problem) == [nil, HotkeyWording.conflictText(.systemRefused, combo: f14, inList: false)])
        #expect(status.keys.last?.problem?.hasPrefix("Refused by macOS") == true)
        hotkeys.isEnabled = false
        #expect(!TimerKeyStatus(hotkeys: hotkeys).hotkeysAreOn)
    }
}
