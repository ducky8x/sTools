import Prologue
import STDesign
import SwiftUI

/// The whole content of the main window: sidebar, a hairline, and the current page — or, on first launch, the
/// introduction with the sidebar hidden until its Finale (spec 4).
struct RootView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openWindow) private var openWindow

    private var showsSidebar: Bool { model.prologue?.showsSidebar ?? true }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                HStack(spacing: 0) {
                    SidebarView(model: model)
                    Rectangle().fill(STColor.rule).frame(width: 1).accessibilityHidden(true)
                }
                // During the Finale the sidebar is there to be watched, not used.
                .allowsHitTesting(model.prologue == nil)
                .transition(model.theme.reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                if let prologue = model.prologue {
                    PrologueView(model: prologue)
                        .id(ObjectIdentifier(prologue))
                        .transition(model.theme.reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .opacity, removal: .offset(x: -80).combined(with: .opacity)))
                } else {
                    PageArea(model: model)
                        .transition(model.theme.reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .offset(x: 60).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .animation(STMotion.resolve(STMotion.page, reduce: model.theme.reduceMotion), value: showsSidebar)
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
