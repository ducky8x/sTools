import Foundation

/// The five tools, in sidebar order.
enum ToolID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case nbbOverlay, windowBackdrop, crosshair, screenRecording, keyRebinder

    var id: String { rawValue }

    /// The 1-5 shown in the sidebar and used by the Go menu shortcuts.
    var number: Int {
        switch self {
        case .nbbOverlay: 1
        case .windowBackdrop: 2
        case .crosshair: 3
        case .screenRecording: 4
        case .keyRebinder: 5
        }
    }

    var title: String {
        switch self {
        case .nbbOverlay: "NBB Overlay"
        case .windowBackdrop: "Window Backdrop"
        case .crosshair: "Crosshair"
        case .screenRecording: "Screen Recording"
        case .keyRebinder: "Key Rebinder"
        }
    }

    /// The shorter name the sidebar line uses, as in the spec's window diagram.
    var sidebarTitle: String {
        switch self {
        case .windowBackdrop: "Backdrop"
        case .screenRecording: "Recording"
        default: title
        }
    }

    /// Rule R13, verbatim.
    var tagline: String {
        switch self {
        case .nbbOverlay: "Ninjabrain Bot's answer, right over the game."
        case .windowBackdrop: "A clean stage behind Minecraft."
        case .crosshair: "The exact center, drawn your way."
        case .screenRecording: "Minecraft and everything else, on one canvas."
        case .keyRebinder: "Every rebind, right on its key."
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

    /// Rendered in small caps, which the label font draws for upper- and lowercase alike.
    var label: String {
        switch self {
        case .on: "ON"
        case .off: "OFF"
        case .alwaysAvailable: "ALWAYS AVAILABLE"
        case .needsAccessibility: "NEEDS ACCESSIBILITY"
        }
    }
}
