import Prologue
import STDesign
import SwiftUI

/// The whole content of the main window: sidebar, a hairline, and the current page — or, on first launch, the
/// introduction with the sidebar hidden until its Finale (spec 4). While motion is reduced nothing beneath it
/// animates (`stMotionRoot`); macOS's own Reduce motion reaches the theme through `SystemMotionWatcher`.
struct RootView: View {
    let model: AppModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openWindow) private var openWindow

    private var showsSidebar: Bool { model.prologue?.showsSidebar ?? true }
    private var reducesMotion: Bool { model.theme.reduceMotion }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                HStack(spacing: 0) {
                    SidebarView(model: model)
                    Rectangle().fill(STColor.rule).frame(width: 1).accessibilityHidden(true)
                }
                // During the Finale the sidebar is there to be watched, not used.
                .allowsHitTesting(model.prologue == nil)
                .transition(reducesMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
            }
            ZStack {
                if let prologue = model.prologue {
                    PrologueView(model: prologue)
                        .id(ObjectIdentifier(prologue))
                        .transition(reducesMotion
                                    ? .identity
                                    : .asymmetric(insertion: .opacity, removal: .offset(x: -80).combined(with: .opacity)))
                } else {
                    PageArea(model: model)
                        .transition(reducesMotion
                                    ? .identity
                                    : .asymmetric(insertion: .offset(x: 60).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .animation(STMotion.resolve(STMotion.page, reduce: reducesMotion), value: showsSidebar)
        .frame(minWidth: 680, minHeight: 500)
        .background(STColor.background)
        .ignoresSafeArea()
        .background(WindowConfigurator(reducesMotion: reducesMotion, onWillClose: { model.mainWindowWillClose() }))
        .stMotionRoot(model.theme)
        .environment(\.stTheme, model.theme)
        .environment(\.stSoundPlayer, model.sound)
        .preferredColorScheme(.dark)
        .onChange(of: contrast, initial: true) { _, value in model.theme.increaseContrast = value == .increased }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}
