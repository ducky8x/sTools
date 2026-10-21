import Foundation

/// A page of the main window.
enum Route: Hashable, Sendable {
    case home
    case tool(ToolID)
    case settings
}

/// A place inside a page that navigation can scroll to.
enum PageAnchor: Hashable, Sendable {
    /// Home ▸ Hotkeys.
    case hotkeys
}

/// Browser-style back/forward history. Pure value type.
struct NavigationHistory: Equatable, Sendable {
    private var entries: [Route]
    private var index: Int
    private let limit: Int

    /// - Parameter limit: The most pages remembered; the oldest are forgotten first.
    init(start: Route = .home, limit: Int = 50) {
        entries = [start]
        index = 0
        self.limit = max(limit, 1)
    }

    var current: Route { entries[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }

    /// Visits `route`, dropping any forward branch. Visiting the current page again changes nothing.
    mutating func push(_ route: Route) {
        guard route != current else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(route)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        index = entries.count - 1
    }

    /// Moves back one page and returns it, or `nil` at the start.
    @discardableResult
    mutating func back() -> Route? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    /// Moves forward one page and returns it, or `nil` at the end.
    @discardableResult
    mutating func forward() -> Route? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}

/// An item of the Go menu.
enum GoCommand: Hashable, Sendable {
    case home, tool(ToolID), settings, back, forward

    /// Every item, in menu order.
    static let menu: [GoCommand] = [.home] + ToolID.allCases.map(GoCommand.tool) + [.settings, .back, .forward]

    /// The page this command opens; `nil` for Back and Forward.
    var route: Route? {
        switch self {
        case .home: .home
        case .tool(let tool): .tool(tool)
        case .settings: .settings
        case .back, .forward: nil
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .tool(let tool): tool.title
        case .settings: "Settings"
        case .back: "Back"
        case .forward: "Forward"
        }
    }

    /// The key pressed with Command.
    var shortcutKey: Character {
        switch self {
        case .home: "0"
        case .tool(let tool): Character(String(tool.number))
        case .settings: ","
        case .back: "["
        case .forward: "]"
        }
    }
}
