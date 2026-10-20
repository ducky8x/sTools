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

    func perform(_ command: GoCommand) {
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
