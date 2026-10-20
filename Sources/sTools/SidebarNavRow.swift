import STDesign
import SwiftUI

/// A single-line sidebar destination: Home or Settings.
struct SidebarNavRow: View {
    let model: AppModel
    let title: String
    let route: Route
    let namespace: Namespace.ID
    @Environment(\.stTheme) private var theme

    private var isSelected: Bool { model.route == route }

    /// Mirrors the accent-colored number in the leading gutter of a tool row, so every sidebar row
    /// reads as a clickable line even at rest instead of only on hover or selection.
    private var icon: String { route == .home ? "house.fill" : "gearshape.fill" }

    var body: some View {
        Button {
            model.navigate(to: route)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 14 * theme.textScale, alignment: .leading)
                Text(title)
                    .stStyle(.sidebarName)
                    .foregroundStyle(STColor.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.leading, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
        .focusEffectDisabled()
        .modifier(SidebarHover(isSelected: isSelected))
        .background {
            if isSelected { SelectionMarker().matchedGeometryEffect(id: "marker", in: namespace) }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
