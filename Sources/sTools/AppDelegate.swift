import AppKit

/// Keeps the app alive after its window closes, reopens the window from the Dock, shuts tools off on quit, and
/// tells the hotkeys whether sTools is in front.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    // Hotkeys pause while sTools is the active app (Home ▸ Hotkeys ▸ Advanced), so every key works in sTools.
    // Only the delegate tells the center, so a pause never outlasts sTools being in front.
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.hotkeys.appIsActive = NSApp.isActive
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.hotkeys.appIsActive = true
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.hotkeys.appIsActive = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let open = model.openMainWindow else { return true }
        open()
        NSApp.activate()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
