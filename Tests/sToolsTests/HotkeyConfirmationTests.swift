import CoreGraphics
import ScreenRecording
import STPlatform
import Testing
@testable import sTools

@Suite("Hotkey confirmation line")
struct HotkeyConfirmationTests {
    @Test func toolsReadInPressOrderJoinedByAMiddleDot() {
        let line = HotkeyConfirmation.summary([.tool(.crosshair, isOn: true), .tool(.nbbOverlay, isOn: true)])
        #expect(line == "Crosshair on \u{00B7} NBB Overlay on")
    }

    @Test func offAndOneToolAlone() {
        #expect(HotkeyConfirmation.summary([.tool(.windowBackdrop, isOn: false)]) == "Window Backdrop off")
    }

    @Test func aToolThatCouldNotSwitchOnSaysWhy() {
        #expect(HotkeyConfirmation.summary([.needsAccessibility(.crosshair)]) == "Crosshair needs Accessibility")
    }

    @Test func recordingPhrases() {
        #expect(HotkeyConfirmation.phrase(.recordingStarted) == "Recording started")
        #expect(HotkeyConfirmation.phrase(.recordingStopped) == "Recording stopped")
        #expect(HotkeyConfirmation.phrase(.recordingCountdown(seconds: 3)) == "Recording starts in 3 seconds")
        #expect(HotkeyConfirmation.phrase(.countdownCanceled) == "Recording canceled")
    }

    @Test func toolsThenRecording() {
        let line = HotkeyConfirmation.summary([.tool(.screenRecording, isOn: true), .recordingStarted])
        #expect(line == "Screen Recording on \u{00B7} Recording started")
    }

    @Test func onlyARealChangeEarnsTheSeal() {
        #expect(HotkeyConfirmation.changedSomething([.tool(.crosshair, isOn: false)]))
        #expect(HotkeyConfirmation.changedSomething([.needsAccessibility(.crosshair), .recordingStopped]))
        #expect(HotkeyConfirmation.changedSomething([.countdownCanceled]))
        #expect(!HotkeyConfirmation.changedSomething([.needsAccessibility(.crosshair), .needsAccessibility(.nbbOverlay)]))
        #expect(!HotkeyConfirmation.changedSomething([.recordingFinishing]))
        #expect(!HotkeyConfirmation.changedSomething([.recordingAwaitingDecision]))
        #expect(!HotkeyConfirmation.changedSomething([]))
    }

    @Test func nothingDoneIsAnEmptyLine() {
        #expect(HotkeyConfirmation.summary([]).isEmpty)
    }

    @Test func recordingEffectFollowsThePhaseBeforeThePress() {
        let cases: [(ScreenRecordingController.Phase, HotkeyConfirmation.Effect)] = [
            (.recording, .recordingStopped),
            (.countingDown(2), .countdownCanceled),
            (.finishing, .recordingFinishing),
            (.deciding, .recordingAwaitingDecision),
            (.idle, .recordingStarted),
        ]
        for (phase, expected) in cases {
            #expect(HotkeyConfirmation.recordingEffect(phase: phase, canStart: true, countdown: .off) == expected)
        }
    }

    @Test func startingWithACountdownSaysWhen() {
        #expect(HotkeyConfirmation.recordingEffect(phase: .idle, canStart: true, countdown: .fiveSeconds)
            == .recordingCountdown(seconds: 5))
    }

    @Test func startingWithoutAccessibilitySaysSo() {
        #expect(HotkeyConfirmation.recordingEffect(phase: .idle, canStart: false, countdown: .off)
            == .needsAccessibility(.screenRecording))
    }

    @Test func stoppingNeedsNothing() {
        #expect(HotkeyConfirmation.recordingEffect(phase: .recording, canStart: false, countdown: .threeSeconds)
            == .recordingStopped)
    }
}

@Suite("Hotkey confirmation placement")
struct HotkeyHUDLayoutTests {
    private func display(_ id: UInt32, frame: CGRect, isMain: Bool = false) -> DisplayInfo {
        DisplayInfo(id: id, name: "Display \(id)", frame: frame, bounds: frame, backingScale: 2,
                    pixelSize: CGSize(width: frame.width * 2, height: frame.height * 2), isMain: isMain)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    ])
    func sitsLowAndCenteredAndClearOfTheCrosshair(displayFrame: CGRect) {
        let size = CGSize(width: 263.4, height: 42.2)
        let frame = HotkeyHUDLayout.frame(contentSize: size, displayFrame: displayFrame)
        #expect(abs(frame.midX - displayFrame.midX) <= 1)
        #expect(frame.width == 264 && frame.height == 43)
        #expect(frame.minY >= displayFrame.minY)
        #expect(frame.maxY < displayFrame.midY - HotkeyHUDLayout.centerClearance + 1)
        #expect(frame.minY >= displayFrame.minY + displayFrame.height * 0.15)
        #expect(!frame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY)))
    }

    @Test func aShortDisplayStillKeepsTheCenterClear() {
        let displayFrame = CGRect(x: 0, y: 0, width: 800, height: 200)
        let frame = HotkeyHUDLayout.frame(contentSize: CGSize(width: 240, height: 40), displayFrame: displayFrame)
        #expect(frame.maxY <= displayFrame.midY)
        #expect(frame.minY >= displayFrame.minY)
    }

    @Test func aLineWiderThanTheDisplayIsCappedToIt() {
        let displayFrame = CGRect(x: 0, y: 0, width: 300, height: 900)
        let frame = HotkeyHUDLayout.frame(contentSize: CGSize(width: 500, height: 40), displayFrame: displayFrame)
        #expect(frame.minX == 0 && frame.width == 300)
    }

    @Test func goesToMinecraftsDisplay() {
        let main = display(1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
        let other = display(2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        #expect(HotkeyHUDLayout.display(minecraftDisplayID: 2, in: [main, other]) == other)
    }

    @Test func fallsBackToTheMainDisplay() {
        let other = display(2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        let main = display(1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
        #expect(HotkeyHUDLayout.display(minecraftDisplayID: nil, in: [other, main]) == main)
        #expect(HotkeyHUDLayout.display(minecraftDisplayID: 9, in: [other, main]) == main)
        #expect(HotkeyHUDLayout.display(minecraftDisplayID: nil, in: []) == nil)
    }
}
