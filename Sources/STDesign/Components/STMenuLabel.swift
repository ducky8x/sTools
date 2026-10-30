import SwiftUI

/// A pop-up menu's label in the app's type: the current choice in body serif with a small chevron. A borderless
/// AppKit menu button draws its label in the system font whatever the label view asks for, so menus that show a
/// choice use this with `stMenuStyle()`.
public struct STMenuLabel: View {
    private let title: String
    private let widest: CGFloat?
    @Environment(\.stTheme) private var theme

    /// `widest` caps the label's width, in points at a text scale of 1; it grows with the text size. A longer title is cut
    /// off with an ellipsis. Without it the label is as wide as its title.
    public init(_ title: String, widest: CGFloat? = nil) {
        self.title = title
        self.widest = widest
    }

    public var body: some View {
        HStack(spacing: 5) {
            name
            Image(systemName: "chevron.down")
                .font(.system(size: 9 * theme.textScale, weight: .semibold))
                .foregroundStyle(theme.inkSecondary)
                .accessibilityHidden(true)
        }
        .capped(at: widest.map { $0 * theme.textScale })
        .contentShape(Rectangle())
    }

    @ViewBuilder private var name: some View {
        let text = Text(title)
            .stStyle(.body)
            .foregroundStyle(STColor.ink)
        if widest != nil { text.lineLimit(1) } else { text }
    }
}

private extension View {
    @ViewBuilder func capped(at width: CGFloat?) -> some View {
        if let width { frame(maxWidth: width) } else { self }
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
