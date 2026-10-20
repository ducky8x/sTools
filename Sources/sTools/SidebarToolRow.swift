import STDesign
import SwiftUI

/// A tool line: number, name, its switch and the live status beneath.
struct SidebarToolRow: View {
    let model: AppModel
    let tool: ToolID
    let namespace: Namespace.ID
    @Environment(\.stTheme) private var theme

    private var route: Route { .tool(tool) }
    private var isSelected: Bool { model.route == route }
    private var status: ToolStatus { model.status(of: tool) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.navigate(to: route)
            } label: {
                label
            }
            .buttonStyle(SidebarButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel("\(tool.number), \(tool.title)")
            .accessibilityValue(status.label.capitalized)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if tool.hasSwitch {
                STSwitch(isOn: model.switchBinding(tool), label: tool.title)
                    .disabled(!model.canSwitch(tool))
                    .padding(.trailing, 4)
            }
        }
        .modifier(SidebarHover(isSelected: isSelected))
        .background {
            if isSelected { SelectionMarker().matchedGeometryEffect(id: "marker", in: namespace) }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text("\(tool.number)")
                    .font(STFont.figures(16 * theme.textScale, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 14 * theme.textScale, alignment: .leading)
                Text(tool.sidebarTitle)
                    .stStyle(.sidebarName)
                    .foregroundStyle(STColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.trailing, 56)
            Text(status.label)
                .stStyle(.label)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .padding(.leading, 22 * theme.textScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.leading, 16)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        status == .on ? theme.accent : theme.inkTertiary
    }
}
