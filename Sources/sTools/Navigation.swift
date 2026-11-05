import Foundation
import KeyRebinder
import SwiftUI

/// A page of the main window.
enum Route: Hashable, Sendable {
    case home
    case hotkeys
    case tool(ToolID)
    case settings
}

/// A place inside a page that navigation can scroll to.
enum PageAnchor: Hashable, Sendable {
    /// The Key Rebinder's panel for the selected key, after the Hotkeys page's Show on Keyboard.
    case keyRebinderKeyPanel

    /// The id the view is marked with: for a view inside another module that can't see this type, the id that module
    /// gives it.
    var scrollID: AnyHashable {
        switch self {
        case .keyRebinderKeyPanel: AnyHashable(KeyRebinderView.keyPanelScrollID)
        }
    }

    /// Where the view lands: the key panel sits mid-view, so the selected key on the keyboard above it stays in sight.
    var scrollAnchor: UnitPoint {
        switch self {
        case .keyRebinderKeyPanel: .center
        }
    }
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
    case home, hotkeys, tool(ToolID), settings, back, forward

    /// Every item, in menu order: the sidebar's, then Back and Forward.
    static let menu: [GoCommand] = [.home, .hotkeys] + ToolID.allCases.map(GoCommand.tool) + [.settings, .back, .forward]

    /// The page this command opens; `nil` for Back and Forward.
    var route: Route? {
        switch self {
        case .home: .home
        case .hotkeys: .hotkeys
        case .tool(let tool): .tool(tool)
        case .settings: .settings
        case .back, .forward: nil
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .hotkeys: "Hotkeys"
        case .tool(let tool): tool.title
        case .settings: "Settings"
        case .back: "Back"
        case .forward: "Forward"
        }
    }

    /// Whether the shortcut holds Control as well as Command. The pages do (⌃⌘0 Home, ⌃⌘H Hotkeys, ⌃⌘1–⌃⌘7 the
    /// tools): hotkeys fire with sTools in front, and a key set's ⌘1–⌘6 would take ⌘ with a digit. Settings, Back and
    /// Forward keep their usual ⌘, ⌘[ and ⌘].
    var shortcutHoldsControl: Bool {
        switch self {
        case .home, .hotkeys, .tool: true
        case .settings, .back, .forward: false
        }
    }

    /// The shortcut as the menu shows it: "⌃⌘3", "⌃⌘H", "⌘,".
    var shortcutDisplay: String { (shortcutHoldsControl ? "⌃⌘" : "⌘") + String(shortcutKey).uppercased() }

    /// The key pressed with Command (and Control, `shortcutHoldsControl`), as the menu takes it: a letter in lowercase,
    /// since an uppercase one would ask for Shift as well. Hotkeys is H for Hotkeys, not a digit, so no key set has it;
    /// macOS keeps no ⌃⌘H, and its ⌘H, Hide, is a combination no hotkey can have, so the menu takes no hotkey's Control
    /// variant.
    var shortcutKey: Character {
        switch self {
        case .home: "0"
        case .hotkeys: "h"
        case .tool(let tool): Character(String(tool.number))
        case .settings: ","
        case .back: "["
        case .forward: "]"
        }
    }
}
