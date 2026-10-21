import STPlatform
import SwiftUI

/// Keeps the permission center polling `permissions` for as long as the page is on screen, when `isNeeded`.
struct PermissionPolling: ViewModifier {
    let permissions: PermissionCenter
    let shown: Set<Permission>
    let isNeeded: Bool
    @State private var token: PermissionCenter.PollingToken?

    func body(content: Content) -> some View {
        content
            .onAppear { start() }
            .onDisappear { stop() }
    }

    private func start() {
        guard isNeeded, token == nil else { return }
        token = permissions.beginPolling(shown)
    }

    private func stop() {
        guard let token else { return }
        self.token = nil
        permissions.endPolling(token)
    }
}

extension View {
    /// Polls only the permissions the page shows: each read but Accessibility's is a round trip to the system.
    func pollsPermissions(_ permissions: PermissionCenter, showing shown: Set<Permission> = [.accessibility],
                          when isNeeded: Bool = true) -> some View {
        modifier(PermissionPolling(permissions: permissions, shown: shown, isNeeded: isNeeded))
    }
}

extension ToolID {
    /// The permissions a tool's page shows the state of: Accessibility, and for Screen Recording its own permission.
    var permissionsShown: Set<Permission> {
        self == .screenRecording ? [.accessibility, .screenRecording] : [.accessibility]
    }
}
