import ScreenRecording
import STPlatform
import TimerOverlay

extension AppModel {
    /// `HotkeyCenter` only toggles three tools (`HotkeyTool`): Key Rebinder has no switch, Screen Recording's key
    /// starts and stops a recording (`.startStopRecording`) and Timer Overlay's key starts the timer (`.startTimer`).
    private static func toolID(for hotkeyTool: HotkeyTool) -> ToolID {
        switch hotkeyTool {
        case .nbbOverlay: .nbbOverlay
        case .windowBackdrop: .windowBackdrop
        case .crosshair: .crosshair
        }
    }

    func hotkeyToolStates() -> [HotkeyTool: Bool] {
        Dictionary(uniqueKeysWithValues: HotkeyTool.allCases.map { ($0, isOn(Self.toolID(for: $0))) })
    }

    /// Home's "Show on Keyboard": asks the Key Rebinder to select the drawn key that sends `combo`'s key, then
    /// opens its page scrolled to that key's panel. False, with the page left as it was, when there is no Key Rebinder or no drawn key sends it.
    @discardableResult
    func showHotkeyOnKeyboard(_ combo: HotkeyCombo) -> Bool {
        guard hotkeys.advisor?.selectKey(for: combo) == true else { return false }
        navigate(to: .tool(.keyRebinder))
        pendingPageAnchor = .keyRebinderKeyPanel
        return true
    }

    /// One hotkey press (spec 6.1's toggle semantics are already resolved by `HotkeyCenter`): carries out its
    /// events in order, then confirms the press once (`confirm`).
    func handleHotkeyPress(_ events: [HotkeyEvent]) {
        confirm(events.compactMap { handleHotkeyEvent($0) })
    }

    /// Confirms what a press did, or what it led to once that happened (a start the key made writing its first
    /// frame): the stamp sound, and unless Home ▸ Hotkeys ▸ Advanced turns it off, the seal with a line of what changed
    /// on Minecraft's display, which VoiceOver announces. Something that changed nothing (a tool needs Accessibility, a
    /// recording that is only starting) gets a plain click and its line without the seal.
    func confirm(_ effects: [HotkeyConfirmation.Effect]) {
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
            // Switching on (when needed) goes through `requestEnable`, which keeps rule R10. The line says what the
            // press did: a second press while the recording starts cancels it rather than starting another. A start
            // isn't confirmed as "Recording started" until its first frame is in the file (`keyStartEnded`); its
            // timings count from when the key went down.
            return HotkeyConfirmation.recordingEffect(recording.toggleRecording(secondsAgo: hotkeys.keyEventAge))
        case .startTimer:
            // The overlay confirms a start, restart, pause or cancel itself, so those add no sound or line (plan
            // decision 5). A press that couldn't switch the tool on (no Accessibility, R10) gets the click and its line,
            // without the seal.
            // The press counts from when its key went down, so the double press measures the keys (spec 5.6.2).
            guard let timer = timerOverlay else { return nil }
            let wasOn = isOn(.timerOverlay)
            let result = timer.press(secondsAgo: hotkeys.keyEventAge)
            if let switchedOff = timerSwitchedOff(timer, wasOn: wasOn) { return switchedOff }
            return result == .couldNotStart ? .needsAccessibility(.timerOverlay) : nil
        case .startTimerReleased:
            // Can arrive from inside a `HotkeyCenter` change, so nothing here may change the hotkeys.
            guard let timer = timerOverlay else { return nil }
            let wasOn = isOn(.timerOverlay)
            timer.release(secondsAgo: hotkeys.keyEventAge)
            return timerSwitchedOff(timer, wasOn: wasOn)
        }
    }

    /// A cancel gesture (a double press, or Advanced's hold) switched Timer Overlay off itself (spec 5.6.2): its switch
    /// follows, and the press is confirmed like any hotkey's switch, "Timer Overlay off" with the seal, because over
    /// the game the overlay leaving looks just like a cancel. Nil when the tool is still on, or was already off.
    private func timerSwitchedOff(_ timer: TimerOverlayController, wasOn: Bool) -> HotkeyConfirmation.Effect? {
        guard !timer.isEnabled else { return nil }
        setTool(.timerOverlay, on: false)
        return wasOn ? .tool(.timerOverlay, isOn: false) : nil
    }
}
