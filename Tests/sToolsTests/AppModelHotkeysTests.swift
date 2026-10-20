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
        harness.model.handleHotkeyEvent(.setTool(.windowBackdrop, isOn: true))
        #expect(harness.model.isOn(.windowBackdrop))
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
