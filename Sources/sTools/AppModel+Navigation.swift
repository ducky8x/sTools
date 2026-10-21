import STDesign

extension AppModel {
    var route: Route { history.current }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Opens `route` and plays the page sound; the current page is left alone.
    func navigate(to route: Route) {
        guard route != history.current else { return }
        history.push(route)
        sound.play(.page)
    }

    /// Opens Home scrolled to its Hotkeys section (the Key Rebinder's Open Hotkeys), even when Home is already open.
    func openHotkeys() {
        pendingPageAnchor = .hotkeys
        navigate(to: .home)
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
            if history.back() != nil { sound.play(.page) }
        case .forward:
            if history.forward() != nil { sound.play(.page) }
        default:
            if let route = command.route { navigate(to: route) }
        }
    }
}
