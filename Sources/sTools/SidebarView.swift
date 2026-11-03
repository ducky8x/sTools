import STDesign
import SwiftUI

/// The custom sidebar: wordmark, Home, Hotkeys, the tools and Settings pinned at the bottom. Its rows fit from the
/// window's 500 pt minimum up at the default text size, closer together below the default height (`SidebarDensity`);
/// larger text that doesn't fit scrolls below the traffic lights' band instead of running off the bottom.
struct SidebarView: View {
    let model: AppModel
    @Environment(\.stTheme) private var theme
    @Namespace private var selection

    /// The band at the top the window's traffic lights sit in, which the rows never scroll into.
    static let lightsBand: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let density = SidebarDensity.forWindow(height: proxy.size.height + Self.lightsBand)
            ScrollView {
                rows(density)
                    .padding(.horizontal, 12)
                    .padding(.bottom, density.bottomPadding)
                    // As tall as the room when the rows fit, so Settings sits at the bottom; taller rows scroll.
                    .frame(minHeight: proxy.size.height, alignment: .top)
            }
            // A scroller would take the switches' room; the rows scroll by trackpad or wheel when they must.
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .environment(\.sidebarDensity, density)
        }
        .padding(.top, Self.lightsBand)
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(STColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private func rows(_ density: SidebarDensity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("sTools")
                .font(STFont.display(30 * theme.textScale))
                .foregroundStyle(STColor.ink)
                // Bodoni Moda's line is half again its size; the wordmark needs little more than its capitals.
                .fixedSize()
                .frame(height: 40 * theme.textScale)
                .padding(.leading, 16)
                .padding(.bottom, density.wordmarkGap)
                .accessibilityAddTraits(.isHeader)
            SidebarNavRow(model: model, title: "Home", route: .home, namespace: selection)
                .modifier(SidebarRowCenter(route: .home, glide: model.sidebarGlide))
            SidebarNavRow(model: model, title: "Hotkeys", route: .hotkeys, namespace: selection)
                .modifier(SidebarRowCenter(route: .hotkeys, glide: model.sidebarGlide))
            Spacer().frame(height: density.groupGap)
            ForEach(ToolID.allCases) { tool in
                SidebarToolRow(model: model, tool: tool, namespace: selection)
                    .modifier(SidebarRowCenter(route: .tool(tool), glide: model.sidebarGlide))
            }
            Spacer(minLength: density.groupGap)
            SidebarNavRow(model: model, title: "Settings", route: .settings, namespace: selection)
                .modifier(SidebarRowCenter(route: .settings, glide: model.sidebarGlide))
        }
        // The marker's spring; its glide and detents are timed by the same curve.
        .stAnimation(SidebarGlide.markerAnimation, value: model.route)
        .coordinateSpace(.named(SidebarRowCenter.space))
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
