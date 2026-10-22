import AppKit
import STDesign
import STPlatform

extension AppModel {
    var route: Route { history.current }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Opens `route` and plays the sidebar marker's glide; the current page is left alone.
    func navigate(to route: Route) {
        guard route != history.current else { return }
        let from = history.current
        history.push(route)
        sidebarGlide.glide(from: from, to: route)
    }

    /// Opens Home scrolled to its Hotkeys section (the Key Rebinder's Open Hotkeys), even when Home is already open.
    func openHotkeys() {
        pendingPageAnchor = .hotkeys
        navigate(to: .home)
    }

    /// Timer Overlay's Set in Hotkeys…: opens Home ▸ Hotkeys with a new hotkey whose action is Start timer, ready
    /// for its key. While hotkeys are off it asks first (plan decision 14); a no opens Home ▸ Hotkeys without the
    /// new hotkey.
    func openHotkeysForStartTimer() {
        if !hotkeys.isEnabled {
            guard confirmTurningOnHotkeys() else {
                openHotkeys()
                return
            }
            hotkeys.isEnabled = true
        }
        pendingNewHotkeyActions = [.startTimer]
        openHotkeys()
    }

    /// The live question behind `confirmTurningOnHotkeys`.
    static func askToTurnOnHotkeys() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Turn on hotkeys?"
        alert.informativeText = "Hotkeys are off, so the Start-timer key would do nothing. Turn them on to set it."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func perform(_ command: GoCommand) {
        // While the introduction runs, ⌘[ and ⌘] are its Back and Skip step, and pages stay closed.
        if let prologue {
            if command == .back { prologue.back() }
            if command == .forward { prologue.skipStep() }
            return
        }
        switch command {
        case .back:
            let from = history.current
            if let to = history.back() { sidebarGlide.glide(from: from, to: to) }
        case .forward:
            let from = history.current
            if let to = history.forward() { sidebarGlide.glide(from: from, to: to) }
        default:
            if let route = command.route { navigate(to: route) }
        }
    }
}
