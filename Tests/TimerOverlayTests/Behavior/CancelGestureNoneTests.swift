import Foundation
import Testing
@testable import TimerOverlay

// The note under Advanced ▸ Cancel gesture ▸ None reads "The key will never turn off the Timer Overlay. Use its
// switch." (spec 5.6.2, revision 42). These tests pin that it's true: with no cancel gesture, nothing the Start-timer
// key does leaves Timer Overlay switched off, whatever the press table does with each press.

/// Key inputs, as (input, seconds): a double press and a third quick press, a hold at the 1 s limit and well past it,
/// then a long hold followed by another double press and hold.
private let keySequences: [[(PressPolicy.Input, TimeInterval)]] = [
    [(.press, 0), (.press, 0.2), (.press, 0.4)],
    [(.press, 0), (.release, 1), (.release, 5)],
    [(.press, 0), (.release, 5), (.press, 6), (.press, 6.2), (.release, 9)],
]

private func settings(gesture: TimerOverlaySettings.CancelGesture, counting: TimerOverlaySettings.PressWhileCounting = .restart,
                      ringing: TimerOverlaySettings.PressWhileRinging = .newCountdown) -> TimerOverlaySettings {
    var settings = TimerOverlaySettings.defaultValue
    settings.cancelGesture = gesture
    settings.pressWhileCounting = counting
    settings.pressWhileRinging = ringing
    return settings
}

/// Every action the sequences give `phase` under `settings`.
private func actions(in phase: TimerPhase, _ settings: TimerOverlaySettings) -> [PressPolicy.Action] {
    keySequences.flatMap { sequence -> [PressPolicy.Action] in
        var policy = PressPolicy()
        return sequence.map { policy.handle($0.0, at: $0.1, phase: phase, settings: settings) }
    }
}

/// Brings a run of the rig's saved duration to `phase`: counting 3 s in, paused there, ringing, or lingering after
/// the alarm.
@MainActor
private func bring(_ rig: TimerRig, to phase: TimerPhase) {
    rig.controller.start()
    switch phase {
    case .paused:
        rig.scheduler.advance(by: 3)
        rig.controller.pause()
    case .ringing:
        rig.runToZero()
    case .lingering:
        rig.runToZero()
        while rig.controller.phase == .ringing, rig.scheduler.fireNext() {}
    default:
        rig.scheduler.advance(by: 3)
    }
}

@Suite("Timer Overlay with no cancel gesture")
struct CancelGestureNoneTests {
    @Test(arguments: TimerPhase.allCases)
    func thePressPolicyNeverAsksToSwitchOff(phase: TimerPhase) {
        for counting in TimerOverlaySettings.PressWhileCounting.allCases {
            for ringing in TimerOverlaySettings.PressWhileRinging.allCases {
                let none = settings(gesture: .off, counting: counting, ringing: ringing)
                #expect(!actions(in: phase, none).contains(.cancelAndSwitchOff), "\(phase), \(counting), \(ringing)")
            }
        }
    }

    /// The control: the same keys do switch it off under a gesture, so the test above isn't vacuous.
    @Test(arguments: [TimerOverlaySettings.CancelGesture.doublePress, .hold], TimerPhase.allCases)
    func theSameKeysSwitchOffWithAGesture(gesture: TimerOverlaySettings.CancelGesture, phase: TimerPhase) {
        #expect(actions(in: phase, settings(gesture: gesture)).contains(.cancelAndSwitchOff))
    }

    /// Through the controller, from every phase a gesture can come in: Timer Overlay stays on and keeps its status.
    @MainActor
    @Test(arguments: [TimerPhase.counting, .paused, .ringing, .lingering])
    func aDoublePressAndAHoldLeaveTheToolOn(phase: TimerPhase) {
        let rig = TimerRig {
            $0.cancelGesture = .off
            $0.durationSeconds = 10
        }
        let timer = rig.controller
        timer.setEnabled(true)
        bring(rig, to: phase)

        timer.press()
        rig.clock.time += 0.2
        timer.press()
        rig.clock.time += 0.2
        timer.press()
        #expect(timer.isEnabled && timer.status != .off, "a double press and a third press leave it on")

        rig.clock.time += 2
        timer.press()
        rig.clock.time += 3
        timer.release()
        #expect(timer.isEnabled && timer.status != .off, "a 3 s hold leaves it on")
    }
}
