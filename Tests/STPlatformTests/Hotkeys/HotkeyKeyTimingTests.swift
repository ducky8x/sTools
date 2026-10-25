import Foundation
import Testing
@testable import STPlatform

/// Reports presses and releases like the Carbon registrar, each stamped with when its key went down or up (seconds of
/// system uptime), readable while the center handles it. Never touches the system.
@MainActor
private final class StampingRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    var onRelease: (@MainActor (UUID) -> Void)?
    private(set) var eventTime: TimeInterval?
    private(set) var active: [UUID: HotkeyCombo] = [:]

    func register(_ combo: HotkeyCombo, id: UUID) throws { active[id] = combo }
    func unregister(id: UUID) { active[id] = nil }

    /// The key went down at `time`.
    func press(_ id: UUID, at time: TimeInterval) { deliver(at: time) { onPress?(id) } }
    /// The key came up at `time`.
    func release(_ id: UUID, at time: TimeInterval) { deliver(at: time) { onRelease?(id) } }

    private func deliver(at time: TimeInterval, _ callback: () -> Void) {
        eventTime = time
        defer { eventTime = nil }
        callback()
    }
}

@MainActor
private final class TimingHarness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hotkey-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store: SettingsStore
    let registrar = StampingRegistrar()
    /// Each handler call.
    var presses: [[HotkeyEvent]] = []
    /// What `keyEventAge` read in each handler call.
    var ages: [TimeInterval] = []
    /// System uptime as the center reads it.
    var now: TimeInterval = 10
    var center: HotkeyCenter!

    init() async {
        store = SettingsStore(directory: directory, debounce: .milliseconds(1))
        store.save(HotkeySettings())
        await store.flush()
        center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] },
                              handler: { [unowned self] events in
                                  presses.append(events)
                                  ages.append(center.keyEventAge)
                              })
        center.uptime = { [unowned self] in now }
        center.isEnabled = true
    }

    /// F13 with Start timer, live.
    @discardableResult
    func addTimerKey() -> UUID { center.add(combo: f13, actions: [.startTimer]) }

    /// Both handed over at `time`, as when sTools gets to a key at once.
    func press(_ id: UUID, at time: TimeInterval) {
        now = max(now, time)
        registrar.press(id, at: time)
    }

    func release(_ id: UUID, at time: TimeInterval) {
        now = max(now, time)
        registrar.release(id, at: time)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private let f13 = HotkeyCombo(keyCode: 105, modifiers: [])

/// When keys move, as macOS and sTools' window stamp them (spec 6.1): a release that never comes, a key reported twice
/// or late, and how long ago the key behind a handler call moved, which Start timer measures its double press with
/// (spec 5.6.2).
@Suite("HotkeyCenter key timing")
@MainActor
struct HotkeyKeyTimingTests {
    // MARK: A release that never comes

    /// A key whose release macOS never reported would otherwise stay down, so every later press would read as a
    /// repeat. A press more than a second after the key was last reported counts as a new one.
    @Test func aMissedReleaseLeavesTheKeyDeadForASecondAtMost() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.press(id, at: 10)
        h.press(id, at: 10.3)
        #expect(h.presses == [[.startTimer]], "a press with no release since is a repeat")
        h.press(id, at: 11.5)
        #expect(h.presses == [[.startTimer], [.startTimer]])
        h.release(id, at: 11.6)
        #expect(h.presses == [[.startTimer], [.startTimer], [.startTimerReleased]])
    }

    /// Once the key counts again, the release it missed can still arrive, late: it's older than the press it would end,
    /// so the key stays down until its own release.
    @Test func theMissedReleaseArrivingLateEndsNothing() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.press(id, at: 10)
        h.press(id, at: 11.5)
        h.release(id, at: 10.1)
        #expect(h.presses == [[.startTimer], [.startTimer]])
        h.release(id, at: 11.6)
        #expect(h.presses == [[.startTimer], [.startTimer], [.startTimerReleased]])
    }

    /// A held key's repeats, if macOS sends any, keep it down however long it's held: each one counts as a fresh report.
    @Test func aHeldKeysRepeatsKeepItDown() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.press(id, at: 10)
        for step in 0..<30 { h.press(id, at: 10.5 + Double(step) * 0.1) }
        h.release(id, at: 13.5)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
        h.press(id, at: 13.7)
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer]])
    }

    /// Taps a quarter second apart, each with its release: two presses, the timer's double press.
    @Test func quickTapsEachCount() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.press(id, at: 10)
        h.release(id, at: 10.08)
        h.press(id, at: 10.25)
        h.release(id, at: 10.33)
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer], [.startTimerReleased]])
    }

    // MARK: One tap reported twice

    /// When sTools' window and macOS both report a key, the tap counts once, whichever report comes first.
    @Test(arguments: [true, false])
    func aTapReportedByTheWindowAndByMacOSCountsOnce(windowFirst: Bool) async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        for (down, up) in [(10.0, 10.08), (10.25, 10.33)] {
            h.now = down
            if windowFirst {
                #expect(h.center.handleKeyDown(keyCode: 105, modifiers: [], isRepeat: false, at: down))
                h.registrar.press(id, at: down)
            } else {
                h.registrar.press(id, at: down)
                #expect(h.center.handleKeyDown(keyCode: 105, modifiers: [], isRepeat: false, at: down))
            }
            h.now = up
            h.registrar.release(id, at: up)
            h.center.handleKeyUp(keyCode: 105, at: up)
        }
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer], [.startTimerReleased]])
    }

    /// The window's reports handled at once and macOS's arriving after them, as when sTools was busy: the late ones
    /// repeat what already counted, so a double tap stays two presses and never becomes a third.
    @Test func lateReportsOfTapsThatCountedAreIgnored() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.now = 10.4
        #expect(h.center.handleKeyDown(keyCode: 105, modifiers: [], isRepeat: false, at: 10))
        #expect(h.center.handleKeyUp(keyCode: 105, at: 10.08))
        #expect(h.center.handleKeyDown(keyCode: 105, modifiers: [], isRepeat: false, at: 10.25))
        h.registrar.press(id, at: 10)
        h.registrar.release(id, at: 10.08)
        h.registrar.press(id, at: 10.25)
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer]])
        h.registrar.release(id, at: 10.33)
        #expect(!h.center.handleKeyUp(keyCode: 105, at: 10.33), "macOS's release already ended it")
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer], [.startTimerReleased]])
    }

    // MARK: When the key moved

    /// While the handler runs, the center says how long ago the key behind the call moved: the time sTools took to
    /// get to it, which Start timer takes off its press.
    @Test func theHandlerHearsHowLongAgoTheKeyMoved() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.now = 10.25
        h.registrar.press(id, at: 10)
        h.now = 10.5
        h.registrar.release(id, at: 10.375)
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
        #expect(h.ages == [0.25, 0.125])
        #expect(h.center.keyEventAge == 0, "outside a handler call there's no key")
    }

    @Test func theWindowsKeysCarryTheirTimes() async {
        let h = await TimingHarness()
        h.addTimerKey()
        h.now = 10.5
        h.center.handleKeyDown(keyCode: 105, modifiers: [], isRepeat: false, at: 10.25)
        h.center.handleKeyUp(keyCode: 105, at: 10.5)
        #expect(h.ages == [0.25, 0])
    }

    /// A press its source didn't stamp, and the releases the center sends itself, happened now.
    @Test func unstampedKeysAndTheCentersOwnReleasesHappenedNow() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.now = 20
        h.registrar.onPress?(id)
        h.now = 25
        h.center.isEnabled = false
        #expect(h.presses == [[.startTimer], [.startTimerReleased]])
        #expect(h.ages == [0, 0])
    }

    /// A key stamped later than now (clocks a hair apart) happened now, never in the future.
    @Test func anAgeIsNeverNegative() async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.now = 10
        h.registrar.press(id, at: 10.01)
        #expect(h.ages == [0])
    }

    /// A time that can't be a key's (0, far ahead, or an hour old, as from another clock) counts as unstamped: every
    /// press still counts, none is taken for a second report of the last, and each happened when sTools got to it.
    /// The Mac has been up a day here, as it usually has.
    @Test(arguments: [0, -5, 186_400, 86_400 - 3_600] as [TimeInterval])
    func aKeyEventWithAnUnusableTimeCountsFromNow(stamp: TimeInterval) async {
        let h = await TimingHarness()
        let id = h.addTimerKey()
        h.now = 86_400
        h.registrar.press(id, at: stamp)
        h.registrar.release(id, at: stamp)
        h.now = 86_400.25
        h.registrar.press(id, at: stamp)
        #expect(h.presses == [[.startTimer], [.startTimerReleased], [.startTimer]])
        #expect(h.ages == [0, 0, 0])
    }
}

/// The real registrar's delivery, without registering a hotkey: events are handed to it the way its Carbon handler
/// hands them over.
@Suite("Carbon hotkey registrar delivery")
@MainActor
struct CarbonHotkeyDeliveryTests {
    /// Each event reaches the center at once, in the order macOS sent it, with the time its key moved readable while
    /// the center handles it.
    @Test func eventsArriveAtOnceWithTheirKeysTime() {
        let registrar = CarbonHotkeyRegistrar()
        var seen: [String] = []
        let id = UUID()
        registrar.onPress = { [unowned registrar] pressed in
            seen.append("press \(pressed == id) \(registrar.eventTime ?? -1)")
        }
        registrar.onRelease = { [unowned registrar] released in
            seen.append("release \(released == id) \(registrar.eventTime ?? -1)")
        }
        registrar.deliver(.pressed, id: id, at: 5)
        registrar.deliver(.released, id: id, at: 5.25)
        #expect(seen == ["press true 5.0", "release true 5.25"])
        #expect(registrar.eventTime == nil)
    }

    /// Carbon calls the handler on the main thread, so the event is handled before the handler returns.
    @Test func onTheMainThreadAnEventIsHandledAtOnce() {
        final class Flag: @unchecked Sendable { var ran = false }
        let flag = Flag()
        CarbonHotkeyRegistrar.runOnMain { flag.ran = true }
        #expect(flag.ran)
    }
}
