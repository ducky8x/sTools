import AppKit

/// Keeps the app alive after its window closes, reopens the window from the Dock, shuts tools off on quit, and
/// keeps hotkeys working while sTools is in front.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var hotkeyKeys: HotkeyKeyWatcher?

    // Hotkeys fire in every app, sTools included; they pause only while sTools listens for raw keys (spec 6.1).
    func applicationDidFinishLaunching(_ notification: Notification) {
        let watcher = HotkeyKeyWatcher(center: model.hotkeys)
        watcher.start()
        hotkeyKeys = watcher
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
