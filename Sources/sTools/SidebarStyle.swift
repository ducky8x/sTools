import STDesign
import SwiftUI

/// The sidebar button look: a press dip and a visible accent focus ring. Selection and hover are drawn by the row.
struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonBody(configuration: configuration)
    }
}

private struct SidebarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.stTheme) private var theme
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.accentStroke, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
            }
    }
}

/// The gold selection marker that glides between sidebar rows: a raised plate with a slim accent bar on its leading edge.
struct SelectionMarker: View {
    @Environment(\.stTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(STColor.raised)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 4)
            }
            .accessibilityHidden(true)
    }
}

/// Background shown behind a row while the pointer is over it and it is not the selected row.
struct SidebarHover: ViewModifier {
    @State private var isHovering = false
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(STColor.raised.opacity(isHovering && !isSelected ? 0.55 : 0))
            }
            .onHover { isHovering = $0 }
    }
}
