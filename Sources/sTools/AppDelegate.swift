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
        // Timer Overlay's countdown on the Dock icon, when its Advanced setting is on (spec 5.6.7).
        model.watchTimerDockBadge { badge in
            if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        }
    }

    /// Start / Pause / Cancel for Timer Overlay, while "Countdown on the Dock icon" is on.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let items = model.timerDockItems
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(timerDockItemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = TimerDockAction(item.action)
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func timerDockItemChosen(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? TimerDockAction)?.action else { return }
        model.performTimerDockItem(action)
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

/// Carries a Dock menu item's timer action through `NSMenuItem.representedObject`.
private final class TimerDockAction: NSObject {
    let action: AppModel.TimerDockItem.Action
    init(_ action: AppModel.TimerDockItem.Action) { self.action = action }
}
