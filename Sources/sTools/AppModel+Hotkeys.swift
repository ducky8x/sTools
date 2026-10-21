import ScreenRecording
import STPlatform

extension AppModel {
    /// `HotkeyCenter` only knows the four switchable tools (`HotkeyTool`); Key Rebinder has no switch
    /// and isn't one of them.
    private static func toolID(for hotkeyTool: HotkeyTool) -> ToolID {
        switch hotkeyTool {
        case .nbbOverlay: .nbbOverlay
        case .windowBackdrop: .windowBackdrop
        case .crosshair: .crosshair
        case .screenRecording: .screenRecording
        }
    }

    func hotkeyToolStates() -> [HotkeyTool: Bool] {
        Dictionary(uniqueKeysWithValues: HotkeyTool.allCases.map { ($0, isOn(Self.toolID(for: $0))) })
    }

    /// Home's "Show on Keyboard": asks the Key Rebinder to select the drawn key that sends `combo`'s key, then
    /// opens its page. False, with the page left as it was, when there is no Key Rebinder or no drawn key sends it.
    @discardableResult
    func showHotkeyOnKeyboard(_ combo: HotkeyCombo) -> Bool {
        guard hotkeys.advisor?.selectKey(for: combo) == true else { return false }
        navigate(to: .tool(.keyRebinder))
        return true
    }

    /// One hotkey press (spec 6.1's toggle semantics are already resolved by `HotkeyCenter`): carries out its
    /// events in order, then confirms the press once — the stamp sound, and unless Home ▸ Hotkeys ▸ Advanced
    /// turns it off, the seal with a line of what changed, on Minecraft's display. A press that changed
    /// nothing (a tool needs Accessibility) gets a plain click and its line without the seal.
    func handleHotkeyPress(_ events: [HotkeyEvent]) {
        let effects = events.compactMap { handleHotkeyEvent($0) }
        guard !effects.isEmpty else { return }
        let changed = HotkeyConfirmation.changedSomething(effects)
        sound.play(changed ? .stamp : .click)
        guard hotkeys.showsConfirmation,
              let display = HotkeyHUDLayout.display(minecraftDisplayID: minecraft.active?.displayID, in: displays.displays)
        else { return }
        hotkeyHUD.present(HotkeyConfirmation.summary(effects), sealed: changed, on: display)
    }

    /// Carries out one event and reports what it did; nil when there was nothing to act on.
    @discardableResult
    func handleHotkeyEvent(_ event: HotkeyEvent) -> HotkeyConfirmation.Effect? {
        switch event {
        case .setTool(let hotkeyTool, let wantsOn):
            let tool = Self.toolID(for: hotkeyTool)
            setTool(tool, on: wantsOn)
            if wantsOn && !isOn(tool) { return .needsAccessibility(tool) }
            return .tool(tool, isOn: isOn(tool))
        case .toggleRecording:
            guard let recording = controller(for: .screenRecording, as: ScreenRecordingController.self) else { return nil }
            let effect = HotkeyConfirmation.recordingEffect(
                phase: recording.phase, canStart: isOn(.screenRecording) || canSwitch(.screenRecording),
                countdown: recording.options.countdown)
            // Switching on (when needed) goes through `requestEnable`, which keeps rule R10.
            recording.toggleRecording()
            return effect
        }
    }
}
