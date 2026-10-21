import AppKit
import Observation
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

/// What a page's background work does while its window can't be seen. Views are hosted off screen; no window is
/// ever ordered onto the screen.
@MainActor
@Suite("Window visibility")
struct WindowVisibilityTests {
    @MainActor @Observable
    final class Visibility {
        var isVisible: Bool
        init(_ isVisible: Bool) { self.isVisible = isVisible }
    }

    struct PollingPage: View {
        let permissions: PermissionCenter
        let visibility: Visibility

        var body: some View {
            Color.clear
                .pollsPermissions(permissions)
                .environment(\.stWindowIsVisible, visibility.isVisible)
        }
    }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test func aPageInAWindowThatCantBeSeenDoesNotPoll() async {
        let permissions = PermissionCenter(prober: FakeProber(), openURL: { _ in }, systemNotifications: NotificationCenter())
        let visibility = Visibility(false)
        let page = host(PollingPage(permissions: permissions, visibility: visibility))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!permissions.isPolling)

        visibility.isVisible = true
        page.layoutSubtreeIfNeeded()
        #expect(await waitUntil { permissions.isPolling })

        // Minimized, closed or behind the game: the poll stops, and starts again when the window comes back.
        visibility.isVisible = false
        page.layoutSubtreeIfNeeded()
        #expect(await waitUntil { !permissions.isPolling })
        visibility.isVisible = true
        page.layoutSubtreeIfNeeded()
        #expect(await waitUntil { permissions.isPolling })
        _ = page
    }

    @Test func aWindowThatWasNeverShownCountsAsUnseen() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(!WindowConfigurator.isVisible(window))
    }

    @Test func theModelStartsOutTreatingTheWindowAsVisible() {
        let harness = Harness()
        #expect(harness.model.isMainWindowVisible)
    }
}
