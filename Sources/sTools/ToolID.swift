import Foundation

/// The seven tools, in sidebar order: the one place that order is written down (spec 3.5). The sidebar, its glide, the Go
/// menu, Home's tiles, the Prologue's tool lists and everything else that follows the sidebar read it from here
/// (`allCases`). The hotkey actions keep the same order in STPlatform, which can't see this type
/// (`HotkeyAction.allCases`); a test checks the two agree.
enum ToolID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case crosshair, timerOverlay, nbbOverlay, screenRecording, windowBackdrop, customCursor, keyRebinder

    var id: String { rawValue }

    /// The 1-7 shown in the sidebar and used by the Go menu shortcuts (⌃⌘1–⌃⌘7) and the ⌘1–⌘6 key set: the tool's
    /// place in the sidebar.
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var title: String {
        switch self {
        case .nbbOverlay: "NBB Overlay"
        case .windowBackdrop: "Window Backdrop"
        case .crosshair: "Crosshair"
        case .timerOverlay: "Timer Overlay"
        case .screenRecording: "Screen Recording"
        case .customCursor: "Custom Cursor"
        case .keyRebinder: "Key Rebinder"
        }
    }

    /// The shorter name the sidebar line uses, as in the spec's window diagram.
    var sidebarTitle: String {
        switch self {
        case .windowBackdrop: "Backdrop"
        case .screenRecording: "Recording"
        case .customCursor: "Cursor"
        default: title
        }
    }

    /// The shortest name, for a Home tile in the narrowest window when even the sidebar's doesn't fit.
    var shortestTitle: String {
        switch self {
        case .timerOverlay: "Timer"
        case .nbbOverlay: "NBB"
        default: sidebarTitle
        }
    }

    /// Rule R13, verbatim, with ducky's M9 rewrites (Crosshair, Timer Overlay, NBB Overlay, Screen Recording, Window Backdrop,
    /// Key Rebinder) and Custom Cursor's (spec 5.7.4).
    var tagline: String {
        switch self {
        case .nbbOverlay: "A clean Ninjabrain Bot overlay."
        case .windowBackdrop: "A backdrop to cover your clutter behind your Minecraft instance."
        case .crosshair: "A crosshair drawn at the center of your screen."
        case .timerOverlay: "A timer for your fire res which you never keep track of."
        case .screenRecording: "A lightweight screen recorder."
        case .customCursor: "Your own pointer for Minecraft\u{2019}s menus."
        case .keyRebinder: "A simple rebinder connected to Karabiner."
        }
    }

    /// Rule R10: these tools turn fully off without Accessibility. Key Rebinder works without it.
    var requiresAccessibility: Bool { self != .keyRebinder }

    /// Key Rebinder is always available, so it has no on/off switch.
    var hasSwitch: Bool { self != .keyRebinder }
}

/// The one-line live status under a tool's name in the sidebar and on Home.
enum ToolStatus: Equatable, Sendable {
    case on, off, alwaysAvailable, needsAccessibility
    /// This macOS lacks what the tool needs (Custom Cursor without the pointer calls), so it can't switch on.
    case notSupported
    /// Timer Overlay's own words while it's on (spec 5.6.3): "Ready", "2:14 left", "Paused, 1:02", "Time's up".
    /// Shown in gold, like *On*.
    case timer(String)

    /// Rendered in small caps, which the label font draws for upper- and lowercase alike.
    var label: String {
        switch self {
        case .on: "ON"
        case .off: "OFF"
        case .alwaysAvailable: "ALWAYS AVAILABLE"
        case .needsAccessibility: "NEEDS ACCESSIBILITY"
        case .notSupported: "NOT SUPPORTED"
        case .timer(let text): text.uppercased()
        }
    }

    /// Whether it reads in gold, as a tool that's on does.
    var isLit: Bool {
        switch self {
        case .on, .timer: true
        case .off, .alwaysAvailable, .needsAccessibility, .notSupported: false
        }
    }
}
