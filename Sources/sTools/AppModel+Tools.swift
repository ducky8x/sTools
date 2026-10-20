import Observation
import STPlatform
import SwiftUI

extension AppModel {
    var accessibilityGranted: Bool { permissions.status(.accessibility) == .granted }

    func isOn(_ tool: ToolID) -> Bool { toolIsOn[tool] ?? false }

    /// Rule R10: a tool that needs Accessibility cannot be switched on without it. Key Rebinder has no switch.
    func canSwitch(_ tool: ToolID) -> Bool {
        tool.hasSwitch && (!tool.requiresAccessibility || accessibilityGranted)
    }

    func status(of tool: ToolID) -> ToolStatus {
        if !tool.hasSwitch { return .alwaysAvailable }
        if isOn(tool) { return .on }
        return canSwitch(tool) ? .off : .needsAccessibility
    }

    /// Flips a tool's switch and drives its controller. Switching on is ignored when `canSwitch` is false.
    func setTool(_ tool: ToolID, on: Bool) {
        guard on != isOn(tool) else { return }
        if on && !canSwitch(tool) { return }
        toolIsOn[tool] = on
        controllers[tool]?.setEnabled(on)
        updateToolPolling()
    }

    func switchBinding(_ tool: ToolID) -> Binding<Bool> {
        Binding(get: { self.isOn(tool) }, set: { self.setTool(tool, on: $0) })
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

    /// While a tool runs the permission center keeps polling, so a revoked grant turns it off promptly.
    private func updateToolPolling() {
        let anyRunning = ToolID.allCases.contains { $0.requiresAccessibility && isOn($0) }
        if anyRunning && !isPollingForTools {
            permissions.beginPolling()
            isPollingForTools = true
        } else if !anyRunning && isPollingForTools {
            permissions.endPolling()
            isPollingForTools = false
        }
    }
}
