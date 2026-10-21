import STPlatform
import Testing
@testable import sTools

@MainActor
@Suite("AppModel hotkeys")
struct AppModelHotkeysTests {
    @Test func toolStatesReflectEachSwitchableToolsOnOffState() {
        let harness = Harness(accessibility: .granted)
        harness.model.setTool(.crosshair, on: true)
        let states = harness.model.hotkeyToolStates()
        #expect(states[.crosshair] == true)
        #expect(states[.nbbOverlay] == false)
        #expect(states[.windowBackdrop] == false)
        #expect(states[.screenRecording] == false)
    }

    @Test func handlingASetToolEventTurnsTheMappedToolOn() {
        let harness = Harness(accessibility: .granted)
        let effect = harness.model.handleHotkeyEvent(.setTool(.windowBackdrop, isOn: true))
        #expect(harness.model.isOn(.windowBackdrop))
        #expect(effect == .tool(.windowBackdrop, isOn: true))
    }

    @Test func handlingAToggleRecordingEventDoesNotCrash() {
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyEvent(.toggleRecording)
    }

    @Test func pressingARegisteredHotkeyTogglesItsToolsUsingAnyOffTurnsAllOnSemantics() async {
        let harness = Harness(accessibility: .granted)
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 8, modifiers: .control), actions: [.toggle(.crosshair), .toggle(.nbbOverlay)])
        harness.model.hotkeys.isEnabled = true
        await harness.model.settings.flush()

        // Simulate the system delivering the press.
        guard let fake = harness.hotkeyRegistrar as? FakeHotkeyRegistrar else {
            Issue.record("expected FakeHotkeyRegistrar")
            return
        }
        fake.onPress?(id)
        #expect(harness.model.isOn(.crosshair))
        #expect(harness.model.isOn(.nbbOverlay))

        // Both on: pressing again turns both off.
        fake.onPress?(id)
        #expect(!harness.model.isOn(.crosshair))
        #expect(!harness.model.isOn(.nbbOverlay))
    }

    @Test func aPressShowsOneConfirmationSayingWhatChanged() {
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true), .setTool(.nbbOverlay, isOn: true)])
        guard !harness.model.displays.displays.isEmpty else { return }
        #expect(harness.hotkeyHUD.lines == ["Crosshair on \u{00B7} NBB Overlay on"])
        #expect(harness.hotkeyHUD.presented.first?.sealed == true)

        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: false), .setTool(.nbbOverlay, isOn: false)])
        #expect(harness.hotkeyHUD.lines.last == "Crosshair off \u{00B7} NBB Overlay off")
        #expect(harness.hotkeyHUD.presented.count == 2)
    }

    @Test func theConfirmationGoesToTheMainDisplayWithoutMinecraft() throws {
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true)])
        guard let main = harness.model.displays.main else { return }
        #expect(try #require(harness.hotkeyHUD.presented.first).displayID == main.id)
    }

    @Test func aToolThatNeedsAccessibilityIsReportedNotClaimed() {
        let harness = Harness(accessibility: .denied)
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true)])
        #expect(!harness.model.isOn(.crosshair))
        guard !harness.model.displays.displays.isEmpty else { return }
        #expect(harness.hotkeyHUD.lines == ["Crosshair needs Accessibility"])
        #expect(harness.hotkeyHUD.presented.first?.sealed == false)
    }

    @Test func turningTheConfirmationOffShowsNothing() {
        let harness = Harness(accessibility: .granted)
        harness.model.hotkeys.showsConfirmation = false
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true)])
        #expect(harness.model.isOn(.crosshair))
        #expect(harness.hotkeyHUD.presented.isEmpty)
    }

    @Test func aPressWithNothingToActOnShowsNothing() {
        // The fake controllers include no Screen Recording controller, so the recording toggle does nothing.
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyPress([.toggleRecording])
        #expect(harness.hotkeyHUD.presented.isEmpty)
    }

    @Test func aRegisteredHotkeyPressIsConfirmedOnce() async {
        let harness = Harness(accessibility: .granted)
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 8, modifiers: .control),
                                           actions: [.toggle(.crosshair), .toggle(.windowBackdrop)])
        harness.model.hotkeys.isEnabled = true
        guard let fake = harness.hotkeyRegistrar as? FakeHotkeyRegistrar else {
            Issue.record("expected FakeHotkeyRegistrar")
            return
        }
        fake.onPress?(id)
        guard !harness.model.displays.displays.isEmpty else { return }
        #expect(harness.hotkeyHUD.lines == ["Crosshair on \u{00B7} Window Backdrop on"])
    }

    @Test func pressingADisabledHotkeySectionDoesNothing() {
        let harness = Harness(accessibility: .granted)
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 8, modifiers: .control), actions: [.toggle(.crosshair)])
        // isEnabled stays false (the default).
        guard let fake = harness.hotkeyRegistrar as? FakeHotkeyRegistrar else {
            Issue.record("expected FakeHotkeyRegistrar")
            return
        }
        fake.onPress?(id)
        #expect(!harness.model.isOn(.crosshair))
    }
}
