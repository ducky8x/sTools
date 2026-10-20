import STPlatform
import SwiftUI

/// Keeps the permission center polling for as long as the page is on screen, when `isNeeded`.
struct PermissionPolling: ViewModifier {
    let permissions: PermissionCenter
    let isNeeded: Bool
    @State private var isPolling = false

    func body(content: Content) -> some View {
        content
            .onAppear { start() }
            .onDisappear { stop() }
    }

    private func start() {
        guard isNeeded, !isPolling else { return }
        isPolling = true
        permissions.beginPolling()
    }

    private func stop() {
        guard isPolling else { return }
        isPolling = false
        permissions.endPolling()
    }
}

extension View {
    func pollsPermissions(_ permissions: PermissionCenter, when isNeeded: Bool = true) -> some View {
        modifier(PermissionPolling(permissions: permissions, isNeeded: isNeeded))
    }
}
