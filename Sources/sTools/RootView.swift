import STDesign
import SwiftUI

/// The whole content of the main window: sidebar, a hairline, and the current page.
struct RootView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Rectangle().fill(STColor.rule).frame(width: 1).accessibilityHidden(true)
            PageArea(model: model)
        }
        .frame(minWidth: 680, minHeight: 500)
        .background(STColor.background)
        .ignoresSafeArea()
        .background(WindowConfigurator(onWillClose: { model.mainWindowWillClose() }))
        .environment(\.stTheme, model.theme)
        .environment(\.stSoundPlayer, model.sound)
        .preferredColorScheme(.dark)
        .onChange(of: reduceMotion, initial: true) { _, value in model.theme.systemReduceMotion = value }
        .onChange(of: contrast, initial: true) { _, value in model.theme.increaseContrast = value == .increased }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}
