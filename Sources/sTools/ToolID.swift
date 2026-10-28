import Foundation

/// The six tools, in sidebar order: the one place that order is written down (spec 3.5). The sidebar, its glide,
/// the Go menu, Home's tool rows, the Prologue's tool lists and everything else that follows the sidebar read it from
/// here (`allCases`). The hotkey actions keep the same order in STPlatform, which can't see this type
/// (`HotkeyAction.allCases`); a test checks the two agree.
enum ToolID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case crosshair, timerOverlay, nbbOverlay, screenRecording, windowBackdrop, keyRebinder

    var id: String { rawValue }

    /// The 1-6 shown in the sidebar and used by the Go menu shortcuts (⌃⌘1–⌃⌘6) and the ⌘1–⌘5 key set: the tool's
    /// place in the sidebar.
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var title: String {
        switch self {
        case .nbbOverlay: "NBB Overlay"
        case .windowBackdrop: "Window Backdrop"
        case .crosshair: "Crosshair"
        case .timerOverlay: "Timer Overlay"
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

    /// Rule R13, verbatim, with ducky's M9 rewrites (Crosshair, NBB Overlay, Screen Recording).
    var tagline: String {
        switch self {
        case .nbbOverlay: "A clean Ninjabrain Bot overlay."
        case .windowBackdrop: "A clean stage behind Minecraft."
        case .crosshair: "A crosshair drawn at the center of your screen."
        case .timerOverlay: "Your Fire Resistance, counted down."
        case .screenRecording: "A lightweight screen recorder."
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
        case .timer(let text): text.uppercased()
        }
    }

    /// Whether it reads in gold, as a tool that's on does.
    var isLit: Bool {
        switch self {
        case .on, .timer: true
        case .off, .alwaysAvailable, .needsAccessibility: false
        }
    }
}
