import Observation
import ScreenRecording
import STPlatform
import SwiftUI
import TimerOverlay

extension AppModel {
    var accessibilityGranted: Bool { permissions.status(.accessibility) == .granted }

    func isOn(_ tool: ToolID) -> Bool { toolIsOn[tool] ?? false }

    /// Rule R10: a tool that needs Accessibility cannot be switched on without it. Key Rebinder has no switch.
    func canSwitch(_ tool: ToolID) -> Bool {
        tool.hasSwitch && (!tool.requiresAccessibility || accessibilityGranted)
    }

    func status(of tool: ToolID) -> ToolStatus {
        if !tool.hasSwitch { return .alwaysAvailable }
        if isOn(tool) {
            // Timer Overlay says where its countdown is instead; `status` changes at most once a second.
            if tool == .timerOverlay, let timer = timerOverlay { return .timer(timer.status.text) }
            return .on
        }
        return canSwitch(tool) ? .off : .needsAccessibility
    }

    /// Flips a tool's switch and drives its controller. Switching on is ignored when `canSwitch` is false. This only
    /// switches: a person's switch-on goes through `userSwitched`, which also starts Timer Overlay's countdown.
    func setTool(_ tool: ToolID, on: Bool) {
        guard on != isOn(tool) else { return }
        if on && !canSwitch(tool) { return }
        toolIsOn[tool] = on
        controllers[tool]?.setEnabled(on)
        updateToolPolling()
    }

    /// Timer Overlay's controller, when the app has one.
    var timerOverlay: TimerOverlayController? { controller(for: .timerOverlay, as: TimerOverlayController.self) }

    /// A tool's switch as the owner sees it, in the sidebar, on the tool's page and in the Prologue's trial.
    func switchBinding(_ tool: ToolID) -> Binding<Bool> {
        Binding(get: { self.isOn(tool) }, set: { self.userSwitched(tool, on: $0) })
    }

    /// The owner flipped a tool's switch. It drives the tool as `setTool` does, except that a switch-on of a tool that
    /// has a key which starts it does what that key does while the tool is off: Timer Overlay starts a countdown
    /// (`startFromSwitch`, spec 5.6.1), Screen Recording starts a recording (spec 5.4.4), confirmed over the game like
    /// the key's press (the line, the sound, "Recording started" once it writes); while the last recording is still
    /// being finished or its question waits there is nothing to start, so that switch-on only switches on. Everything
    /// else that switches a tool (a hotkey, the controller asking for itself, restoring the tools at launch,
    /// Accessibility being revoked, the Prologue) calls `setTool`, which only switches, so nothing but a person's
    /// switch-on starts a countdown or a recording by itself.
    func userSwitched(_ tool: ToolID, on: Bool) {
        guard on, !isOn(tool) else { return setTool(tool, on: on) }
        switch tool {
        case .timerOverlay:
            if let timer = timerOverlay {
                timer.startFromSwitch()
                return
            }
        case .screenRecording:
            if let recording = controller(for: .screenRecording, as: ScreenRecordingController.self),
               let press = recording.startFromSwitch() {
                confirm([press].compactMap(HotkeyConfirmation.recordingEffect))
                return
            }
        default:
            break
        }
        setTool(tool, on: on)
    }

    /// Asks macOS for Accessibility; when that leaves it missing, opens its System Settings pane.
    func allowAccessibility() async {
        await permissions.request(.accessibility)
        if !accessibilityGranted { permissions.openSettings(for: .accessibility) }
    }

    /// Reacts to an Accessibility change: refreshes Minecraft when it was just granted and
    /// turns every tool that needs it off when it was revoked.
    func reconcileAccessibility() {
        let granted = accessibilityGranted
        if granted && !wasAccessibilityGranted { minecraft.refresh() }
        if !granted {
            for tool in ToolID.allCases where tool.requiresAccessibility && isOn(tool) { setTool(tool, on: false) }
        }
        wasAccessibilityGranted = granted
    }

    /// Re-arms itself after each change, so revocation is noticed whichever page is showing.
    func watchAccessibility() {
        withObservationTracking {
            _ = permissions.status(.accessibility)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconcileAccessibility()
                self?.watchAccessibility()
            }
        }
    }

    /// How often a running tool rereads Accessibility in case the system's change notice never comes. The notice and
    /// sTools becoming active reread it at once; this is only the backstop, slow enough to cost nothing during a run.
    static let toolPollingInterval: Duration = .seconds(15)

    var isPollingForTools: Bool { toolPolling != nil }

    /// While a tool runs the permission center watches Accessibility (and only Accessibility, the one these tools
    /// need), so a revoked grant turns them off.
    private func updateToolPolling() {
        let anyRunning = ToolID.allCases.contains { $0.requiresAccessibility && isOn($0) }
        if anyRunning && toolPolling == nil {
            toolPolling = permissions.beginPolling([.accessibility], interval: Self.toolPollingInterval)
        } else if !anyRunning, let token = toolPolling {
            permissions.endPolling(token)
            toolPolling = nil
        }
    }
}
