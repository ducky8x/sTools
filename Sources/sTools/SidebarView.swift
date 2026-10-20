import STDesign
import SwiftUI

/// The custom sidebar: wordmark, Home, the five tools and Settings pinned at the bottom.
struct SidebarView: View {
    let model: AppModel
    @Environment(\.stTheme) private var theme
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("sTools")
                .font(STFont.display(30 * theme.textScale))
                .foregroundStyle(STColor.ink)
                .padding(.leading, 16)
                .padding(.bottom, 20)
                .accessibilityAddTraits(.isHeader)
            SidebarNavRow(model: model, title: "Home", route: .home, namespace: selection)
            Spacer().frame(height: 14)
            ForEach(ToolID.allCases) { tool in
                SidebarToolRow(model: model, tool: tool, namespace: selection)
            }
            Spacer(minLength: 12)
            SidebarNavRow(model: model, title: "Settings", route: .settings, namespace: selection)
        }
        .stAnimation(STMotion.standard, value: model.route)
        .padding(.top, 46)
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(STColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }
}
