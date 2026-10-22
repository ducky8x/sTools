import Foundation
@testable import STPlatform
import Testing
import TimerOverlay
@testable import sTools

/// Reports presses and releases the way the real registrar does: each one stamped with when its key moved (system
/// uptime), readable while sTools handles it. Never registers a real hotkey.
@MainActor
private final class KeyboardRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    var onRelease: (@MainActor (UUID) -> Void)?
    private(set) var eventTime: TimeInterval?
    private(set) var registered: [UUID: HotkeyCombo] = [:]

    func register(_ combo: HotkeyCombo, id: UUID) throws { registered[id] = combo }
    func unregister(id: UUID) { registered[id] = nil }

    func deliver(_ edge: (UUID) -> Void, _ id: UUID, at time: TimeInterval) {
        eventTime = time
        defer { eventTime = nil }
        edge(id)
    }
}

/// The uptime clock the hotkey center reads.
@MainActor
private final class Uptime {
    var now: TimeInterval = 0
}

/// ducky's `hotkeys.json` and `timerOverlay.json` as saved on 2026-10-21, read as the app reads them: ⌘1 Crosshair,
/// ⌘2 Start timer, ⌘3 NBB Overlay, ⌘4 Screen Recording, ⌘5 Window Backdrop, with hotkeys on and the confirmation
/// shown; a 2:30 countdown that restarts on a press and is cancelled by a double press.
private enum DuckysFiles {
    static let startTimerKey = UUID(uuidString: "B07505BD-1003-409C-A80A-44B711361138")!

    static let hotkeys = """
        {"bindings":[
        {"actions":["toggle.crosshair"],"combo":{"keyCode":18,"modifiers":256},"id":"5D43948D-3289-4E2D-897E-A3ADC311524F"},
        {"actions":["startTimer"],"combo":{"keyCode":19,"modifiers":256},"id":"B07505BD-1003-409C-A80A-44B711361138"},
        {"actions":["toggle.nbbOverlay"],"combo":{"keyCode":20,"modifiers":256},"id":"94713406-6602-4D45-91D4-007A0FC88331"},
        {"actions":["startStopRecording"],"combo":{"keyCode":21,"modifiers":256},"id":"C5C8BB8E-71E5-4052-B536-222FD63835F1"},
        {"actions":["toggle.windowBackdrop"],"combo":{"keyCode":23,"modifiers":256},"id":"6AFE1BF8-F53C-4A85-BDC7-95ADE4514E80"}
        ],"isEnabled":true,"showsConfirmation":true}
        """

    static let timer = """
        {"alarmInRecordings":false,"atZero":"holdZero","atZeroWord":"Time","beforeZero":"nothing",
        "cancelGesture":"doublePress","chimeAtSeconds":30,"digitSize":40,"displayChoice":"followMinecraft",
        "durationSeconds":150,"fontFamily":"Source Serif 4","guiScale":3,"labelText":"Fire res","leave":"afterLastRing",
        "leaveAfterLastRingSeconds":2,"leaveAfterZeroSeconds":5,"look":"plate","nearZero":"off","nearZeroDangerSeconds":10,
        "nearZeroGoldSeconds":30,"offsetX":450,"offsetY":-460,"pausesWhileMinecraftNotFocused":false,
        "placementModeEnabled":false,"popUpMotion":"springPop","pressWhileCounting":"restart",
        "pressWhileRinging":"newCountdown","progress":"off","rings":3,"ruleNote":"off","ruleNoticeDismissed":false,
        "showsDockCountdown":false,"showsInRecordings":true,"showsLabel":false,"showsRuleGuides":true,"showsTenths":false,
        "snappingEnabled":true,"soundID":"macOS:Ping","speedRunIGTCorner":"topRight","timeFormat":"minutesAndSeconds",
        "visibleOnlyWhileMinecraftFocused":false,"volume":0.8,"whilePaused":"hideAfterDelay","whileRinging":"pulsePerRing"}
        """

    static func decode<D: Decodable>(_ type: D.Type, _ json: String) throws -> D {
        try JSONDecoder().decode(D.self, from: Data(json.utf8))
    }
}

/// sTools with ducky's files and a keyboard: each key moves at a second of the test (`at`) and reaches sTools `late`
/// seconds after, with the hotkey center's uptime and the timer's clock moving together.
@MainActor
private final class Keyboard {
    let harness: Harness
    private let registrar: KeyboardRegistrar
    private let uptime: Uptime
    /// The uptime and the timer's clock at the test's second 0.
    private let uptimeZero: TimeInterval
    private let timerZero: TimeInterval

    init(uptimeZero: TimeInterval = 500) throws {
        let registrar = KeyboardRegistrar()
        let uptime = Uptime()
        let harness = Harness(hotkeyRegistrar: registrar,
                              hotkeys: try DuckysFiles.decode(HotkeySettings.self, DuckysFiles.hotkeys))
        harness.timer.settings = try DuckysFiles.decode(TimerOverlaySettings.self, DuckysFiles.timer)
        harness.model.hotkeys.uptime = { uptime.now }
        self.registrar = registrar
        self.uptime = uptime
        self.harness = harness
        self.uptimeZero = uptimeZero
        timerZero = harness.timerFakes.clock.time
        moveClocks(to: 0)
    }

    var model: AppModel { harness.model }
    var timer: TimerOverlayController { harness.timer }
    var hudLines: [String] { harness.hotkeyHUD.lines }
    /// How many countdowns have started, restarts included.
    var starts: Int { harness.timerFakes.announcer.announcements.filter { if case .started = $0 { true } else { false } }.count }

    /// ⌘2 goes down at `at` and up `held` seconds later.
    func tap(at time: TimeInterval, held: TimeInterval = 0.08, late: TimeInterval = 0) {
        press(at: time, late: late)
        release(at: time + held, late: late)
    }

    func press(at time: TimeInterval, late: TimeInterval = 0) {
        moveClocks(to: time + late)
        registrar.deliver({ registrar.onPress?($0) }, DuckysFiles.startTimerKey, at: uptimeZero + time)
    }

    func release(at time: TimeInterval, late: TimeInterval = 0) {
        moveClocks(to: time + late)
        registrar.deliver({ registrar.onRelease?($0) }, DuckysFiles.startTimerKey, at: uptimeZero + time)
    }

    private func moveClocks(to time: TimeInterval) {
        uptime.now = uptimeZero + time
        harness.timerFakes.clock.time = timerZero + time
    }
}

/// ducky's request: "double tapping should turn off the toggle. rehitting the keybind reopens it anyways", and
/// "pausing keeping it on is ok". The Start-timer key (⌘2 in ducky's files) driven the way macOS reports a keyboard:
/// each tap a press and a release, stamped with when the key moved, through Hotkeys to Timer Overlay and its switch.
@MainActor
@Suite("Timer Overlay's key, tapped")
struct TimerKeyTapTests {
    @Test func duckysFilesLoad() throws {
        let keys = try Keyboard()
        #expect(keys.model.hotkeys.isEnabled && keys.model.hotkeys.scope == .sToolsAndMinecraft)
        #expect(keys.model.hotkeys.status(of: DuckysFiles.startTimerKey) == .registered)
        #expect(keys.timer.settings.cancelGesture == .doublePress && keys.timer.settings.pressWhileCounting == .restart)
        #expect(keys.timer.settings.durationSeconds == 150)
    }

    /// Tap, tap: Timer Overlay switches off, its switch with it, and over the game it says so. The next tap switches
    /// it back on with a fresh 2:30.
    @Test func aDoubleTapSwitchesTheToolOffAndTheNextTapBringsItBack() throws {
        let keys = try Keyboard()
        keys.tap(at: 0)
        #expect(keys.model.isOn(.timerOverlay) && keys.timer.phase == .counting && keys.timer.content.text == "02:30")
        #expect(keys.hudLines.isEmpty, "the countdown popping up is the confirmation")

        keys.tap(at: 0.25)
        #expect(!keys.model.isOn(.timerOverlay) && !keys.timer.isEnabled && keys.timer.phase == .idle)
        #expect(keys.model.status(of: .timerOverlay) == .off)
        #expect(keys.hudLines == ["Timer Overlay off"])
        #expect(keys.harness.hotkeyHUD.presented.last?.sealed == true)

        keys.tap(at: 1.25)
        #expect(keys.model.isOn(.timerOverlay) && keys.timer.phase == .counting && keys.timer.content.text == "02:30")
        #expect(keys.model.status(of: .timerOverlay) == .timer("2:30 left"))
        #expect(keys.hudLines == ["Timer Overlay off"])
    }

    /// A third quick tap after a double tap is a first press again: it switches the tool back on and starts.
    @Test func aThirdQuickTapStartsAgain() throws {
        let keys = try Keyboard()
        keys.tap(at: 0)
        keys.tap(at: 0.25)
        keys.tap(at: 0.5)
        #expect(keys.model.isOn(.timerOverlay) && keys.timer.phase == .counting && keys.timer.content.text == "02:30")
    }

    /// Taps further apart than the double press restart the countdown, and the tool stays on.
    @Test func aLaterTapRestarts() throws {
        let keys = try Keyboard()
        keys.tap(at: 0)
        keys.tap(at: 3)
        #expect(keys.model.isOn(.timerOverlay) && keys.timer.phase == .counting && keys.timer.content.text == "02:30")
        #expect(keys.starts == 2 && keys.hudLines.isEmpty)
    }

    /// The double press measures the keys, not when sTools got to them: a second tap 0.3 s after the first still
    /// switches the tool off when sTools gets to it 0.3 s late, busy with the first tap's countdown.
    @Test func aSecondTapHandledLateStillSwitchesTheToolOff() throws {
        let keys = try Keyboard()
        keys.tap(at: 0)
        keys.tap(at: 0.3, late: 0.3)
        #expect(!keys.model.isOn(.timerOverlay) && keys.hudLines == ["Timer Overlay off"])
    }

    /// A key held down sends no second press, and its repeats, if macOS sends any, are no double press.
    @Test func holdingTheKeyIsOnePress() throws {
        let keys = try Keyboard()
        keys.press(at: 0)
        keys.press(at: 0.3)
        keys.press(at: 0.35)
        keys.release(at: 0.5)
        #expect(keys.model.isOn(.timerOverlay) && keys.timer.phase == .counting && keys.starts == 1)
    }

    /// When a key's release never arrives, the key isn't left dead: a tap over a second later counts.
    @Test func aTapAfterAMissedReleaseStillWorks() throws {
        let keys = try Keyboard()
        keys.press(at: 0)
        keys.tap(at: 1.5)
        #expect(keys.model.isOn(.timerOverlay) && keys.starts == 2, "a new press: a restart")
        keys.tap(at: 1.75)
        #expect(!keys.model.isOn(.timerOverlay), "and a double tap works again")
    }

    /// "Pausing keeping it on is ok": with Advanced's "Pauses or resumes", a tap pauses and the tool stays on, and a
    /// double tap after a pause and resume still switches it off.
    @Test func pausingKeepsTheToolOnAndADoubleTapStillSwitchesItOff() throws {
        let keys = try Keyboard()
        keys.timer.settings.pressWhileCounting = .pauseOrResume
        keys.tap(at: 0)
        keys.tap(at: 2)
        #expect(keys.timer.phase == .paused && keys.model.isOn(.timerOverlay))
        #expect(keys.model.status(of: .timerOverlay) == .timer("Paused, 2:28"))
        keys.tap(at: 4)
        #expect(keys.timer.phase == .counting && keys.model.isOn(.timerOverlay))
        keys.tap(at: 6)
        keys.tap(at: 6.25)
        #expect(!keys.model.isOn(.timerOverlay) && keys.hudLines == ["Timer Overlay off"])
    }

    /// Advanced's hold: holding the key a second switches the tool off and says so; a tap only starts.
    @Test func holdingTheKeyASecondWithTheHoldGestureSwitchesTheToolOff() throws {
        let keys = try Keyboard()
        keys.timer.settings.cancelGesture = .hold
        keys.tap(at: 0, held: 0.3)
        #expect(keys.model.isOn(.timerOverlay))
        keys.tap(at: 2, held: 1.2)
        #expect(!keys.model.isOn(.timerOverlay) && keys.hudLines == ["Timer Overlay off"])
    }
}

/// Copy Diagnostics reads the unified log (`OSLogLineReader`), which keeps notice-level lines: a double tap can be
/// followed there from the keys to the switch.
@MainActor
@Suite("Timer Overlay's key in the log")
struct TimerKeyLogTests {
    @Test func aDoubleTapCanBeFollowedInTheLogCopyDiagnosticsReads() async throws {
        let since = Date().addingTimeInterval(-1)
        // Its own uptime, so its lines can't be mistaken for another test's.
        let keys = try Keyboard(uptimeZero: 7_321)
        keys.tap(at: 0)
        keys.tap(at: 0.25)
        // The unified log can take a moment to hand back what was just written.
        let deadline = ContinuousClock.now + .seconds(15)
        var lines: [String] = []
        repeat {
            lines = try OSLogLineReader().recentLines(since: since, limit: 10_000)
            if lines.contains(where: { $0.contains("Timer Overlay on \u{2192} off") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        #expect(lines.contains { $0.contains("\u{2318}2 from macOS at 7321.000 down: counted, Start timer") })
        #expect(lines.contains { $0.contains("\u{2318}2 from macOS at 7321.250 down: counted, Start timer") })
        #expect(lines.contains { $0.contains("counting \u{2192} cancelAndSwitchOff; Timer Overlay on \u{2192} off") })
    }
}
