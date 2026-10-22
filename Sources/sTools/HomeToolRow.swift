import STDesign
import SwiftUI

/// One tool on Home: number, name and live status. Opens the tool's page.
struct HomeToolRow: View {
    let model: AppModel
    let tool: ToolID
    @Environment(\.stTheme) private var theme

    private var status: ToolStatus { model.status(of: tool) }

    var body: some View {
        Button {
            model.navigate(to: .tool(tool))
        } label: {
            HStack(spacing: 12) {
                Text("\(tool.number)")
                    .font(STFont.figures(16 * theme.textScale, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 18 * theme.textScale, alignment: .leading)
                Text(tool.title)
                    .stStyle(.body)
                    .foregroundStyle(STColor.ink)
                Spacer(minLength: 16)
                Text(status.label)
                    .stStyle(.label)
                    .foregroundStyle(status.isLit ? theme.accent : theme.inkSecondary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
        }
        .buttonStyle(SidebarButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel("\(tool.number), \(tool.title)")
        .accessibilityValue(status.label.capitalized)
        .accessibilityHint("Opens the \(tool.title) page")
    }
}
