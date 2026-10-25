import Foundation

/// Home ▸ Hotkeys ▸ Where hotkeys work (spec 6.1). The raw value is the stored name.
public enum HotkeyScope: String, Codable, CaseIterable, Hashable, Sendable {
    /// Only while sTools or a Minecraft instance is the app in front (the default). In every other app nothing is
    /// registered, so the keys reach that app untouched: a browser's ⌘1 still switches tabs.
    case sToolsAndMinecraft
    /// Whichever app is in front.
    case everywhere

    /// The choice's name in the chooser.
    public var title: String {
        switch self {
        case .sToolsAndMinecraft: "In sTools and Minecraft"
        case .everywhere: "Everywhere"
        }
    }
}

/// The app in front, sorted the way Where hotkeys work needs it.
public enum HotkeyFrontApp: Hashable, Sendable {
    case sTools
    /// A Minecraft instance the locator knows (spec R11 lists them all, not only the one the tools follow).
    case minecraft
    /// Any other app.
    case other
}
