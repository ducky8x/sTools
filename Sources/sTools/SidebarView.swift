import STDesign
import SwiftUI

/// The custom sidebar: wordmark, Home, the tools and Settings pinned at the bottom.
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
                .modifier(SidebarRowCenter(route: .home, glide: model.sidebarGlide))
            Spacer().frame(height: 14)
            ForEach(ToolID.allCases) { tool in
                SidebarToolRow(model: model, tool: tool, namespace: selection)
                    .modifier(SidebarRowCenter(route: .tool(tool), glide: model.sidebarGlide))
            }
            Spacer(minLength: 12)
            SidebarNavRow(model: model, title: "Settings", route: .settings, namespace: selection)
                .modifier(SidebarRowCenter(route: .settings, glide: model.sidebarGlide))
        }
        // The marker's spring; its glide and detents are timed by the same curve.
        .stAnimation(SidebarGlide.markerAnimation, value: model.route)
        .coordinateSpace(.named(SidebarRowCenter.space))
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

/// Tells the glide where a row's center is, so each detent lands as the marker's center crosses it. Reports only
/// when the layout changes.
private struct SidebarRowCenter: ViewModifier {
    nonisolated static let space = "sidebar"
    let route: Route
    let glide: SidebarGlidePlayer

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(Self.space)).midY
        } action: { center in
            glide.layout.centers[route] = center
        }
    }
}
