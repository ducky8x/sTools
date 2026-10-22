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
        #expect(HotkeyConfirmation.phrase(.recordingStarting) == "Starting the recording\u{2026}")
        #expect(HotkeyConfirmation.phrase(.recordingStarted) == "Recording started")
        // The stop switches the tool off too, so the line says so, as Timer Overlay's cancel says "Timer Overlay off".
        #expect(HotkeyConfirmation.phrase(.recordingStopped) == "Recording stopped \u{00B7} Screen Recording off")
        #expect(HotkeyConfirmation.phrase(.recordingCountdown(seconds: 3)) == "Recording starts in 3 seconds")
        // A canceled start switches the tool off too, and says so the same way.
        #expect(HotkeyConfirmation.phrase(.recordingCanceled) == "Recording canceled \u{00B7} Screen Recording off")
        #expect(HotkeyConfirmation.phrase(.recordingCouldNotStart("the disk is almost full"))
            == "Recording couldn\u{2019}t start: the disk is almost full \u{00B7} Screen Recording off")
    }

    @Test func toolsThenRecording() {
        let line = HotkeyConfirmation.summary([.tool(.screenRecording, isOn: true), .recordingStarted])
        #expect(line == "Screen Recording on \u{00B7} Recording started")
    }

    @Test func onlyARealChangeEarnsTheSeal() {
        #expect(HotkeyConfirmation.changedSomething([.tool(.crosshair, isOn: false)]))
        #expect(HotkeyConfirmation.changedSomething([.needsAccessibility(.crosshair), .recordingStopped]))
        #expect(HotkeyConfirmation.changedSomething([.recordingCanceled]))
        #expect(!HotkeyConfirmation.changedSomething([.needsAccessibility(.crosshair), .needsAccessibility(.nbbOverlay)]))
        #expect(!HotkeyConfirmation.changedSomething([.recordingFinishing]))
        #expect(!HotkeyConfirmation.changedSomething([.recordingAwaitingDecision]))
        // A start that's still waiting for its first frame hasn't recorded anything yet.
        #expect(!HotkeyConfirmation.changedSomething([.recordingStarting]))
        #expect(HotkeyConfirmation.changedSomething([.recordingStarted]))
        #expect(!HotkeyConfirmation.changedSomething([]))
    }

    @Test func nothingDoneIsAnEmptyLine() {
        #expect(HotkeyConfirmation.summary([]).isEmpty)
    }

    /// The line follows what the press did, which the controller reports as the press returns. A start says nothing of
    /// "Recording started" yet: that comes once the recording writes (`recordingStartEffect`). While its sources start,
    /// the press says it's starting; with them already running, the press has no line of its own.
    @Test func recordingEffectSaysWhatThePressDid() {
        let cases: [(ScreenRecordingController.KeyPress, HotkeyConfirmation.Effect?)] = [
            (.starting(waitsForSources: true), .recordingStarting),
            (.starting(waitsForSources: false), nil),
            (.countdown(seconds: 5), .recordingCountdown(seconds: 5)),
            (.stopped, .recordingStopped),
            (.canceled, .recordingCanceled),
            (.finishing, .recordingFinishing),
            (.awaitingDecision, .recordingAwaitingDecision),
            (.couldNotSwitchOn, .needsAccessibility(.screenRecording)),
            (.needsPermission, .recordingNeedsPermission),
        ]
        for (press, expected) in cases {
            #expect(HotkeyConfirmation.recordingEffect(press) == expected)
        }
    }

    /// A press that started nothing gets its line without the seal.
    @Test func aStartThatCouldNotSwitchOnEarnsNoSeal() throws {
        let effect = try #require(HotkeyConfirmation.recordingEffect(.couldNotSwitchOn))
        #expect(!HotkeyConfirmation.changedSomething([effect]))
        #expect(HotkeyConfirmation.summary([effect]) == "Screen Recording needs Accessibility")
    }

    /// Once a start the key made writes its first frame, the line is "Recording started", with the seal.
    @Test func aStartThatWritesSaysRecordingStarted() {
        let effect = HotkeyConfirmation.recordingStartEffect(.started)
        #expect(effect == .recordingStarted)
        #expect(HotkeyConfirmation.changedSomething([effect]))
        #expect(HotkeyConfirmation.summary([effect]) == "Recording started")
    }

    /// A start that fails after the press says why, and that the tool switched off, without the seal: nothing was
    /// recorded.
    @Test func aStartThatFailsSaysWhy() {
        let effect = HotkeyConfirmation.recordingStartEffect(.failed("the disk is almost full"))
        #expect(effect == .recordingCouldNotStart("the disk is almost full"))
        #expect(!HotkeyConfirmation.changedSomething([effect]))
        #expect(HotkeyConfirmation.summary([effect])
            == "Recording couldn\u{2019}t start: the disk is almost full \u{00B7} Screen Recording off")
    }

    /// Without Screen & System Audio Recording nothing starts, so the line names the permission and earns no seal.
    @Test func aStartWithoutScreenRecordingPermissionSaysWhatsMissing() {
        #expect(HotkeyConfirmation.phrase(.recordingNeedsPermission) == "Screen Recording needs Screen & System Audio Recording")
        #expect(!HotkeyConfirmation.changedSomething([.recordingNeedsPermission]))
        #expect(HotkeyConfirmation.changedSomething([.tool(.crosshair, isOn: true), .recordingNeedsPermission]))
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
