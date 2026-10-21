import SwiftUI

/// A pop-up menu's label in the app's type: the current choice in body serif with a small chevron. A borderless
/// AppKit menu button draws its label in the system font whatever the label view asks for, so menus that show a
/// choice use this with `stMenuStyle()`.
public struct STMenuLabel: View {
    private let title: String
    @Environment(\.stTheme) private var theme

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .stStyle(.body)
                .foregroundStyle(STColor.ink)
            Image(systemName: "chevron.down")
                .font(.system(size: 9 * theme.textScale, weight: .semibold))
                .foregroundStyle(theme.inkSecondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

public extension View {
    /// Draws a `Menu` with its SwiftUI label as is, with no AppKit bezel or indicator of its own.
    func stMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
