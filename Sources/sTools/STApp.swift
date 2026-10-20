import AppKit
import STDesign
import SwiftUI

@main
struct STApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        STFont.register()
    }

    var body: some Scene {
        Window("sTools", id: "main") {
            RootView(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)
        .commands { GoCommands(model: delegate.model) }
    }
}
