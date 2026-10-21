import STDesign
import SwiftUI

/// The page for the current route. Pages slide in and fade; while motion is reduced they change in place.
struct PageArea: View {
    let model: AppModel
    @Environment(\.stTheme) private var theme

    var body: some View {
        ZStack {
            page
                .id(model.route)
                .transition(transition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(STMotion.resolve(STMotion.page, reduce: theme.reduceMotion), value: model.route)
    }

    private var transition: AnyTransition {
        theme.reduceMotion
            ? .identity
            : .asymmetric(insertion: .offset(x: 28).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder private var page: some View {
        switch model.route {
        case .home: HomePage(model: model)
        case .settings: SettingsPage(model: model)
        case .tool(let tool): ToolPage(model: model, tool: tool)
        }
    }
}
