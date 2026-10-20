import STDesign
import SwiftUI

/// The Go menu, plus Settings in the app menu in place of the standard (unused) settings command.
struct GoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            item(.settings, title: "Settings\u{2026}")
        }
        CommandMenu("Go") {
            ForEach(GoCommand.menu, id: \.self) { command in
                item(command, title: command.title)
                if command == .tool(.keyRebinder) || command == .settings { Divider() }
            }
        }
    }

    @ViewBuilder
    private func item(_ command: GoCommand, title: String) -> some View {
        Button(title) { model.perform(command) }
            .keyboardShortcut(KeyEquivalent(command.shortcutKey), modifiers: .command)
            .disabled(isDisabled(command))
    }

    private func isDisabled(_ command: GoCommand) -> Bool {
        switch command {
        case .back: !model.canGoBack
        case .forward: !model.canGoForward
        default: false
        }
    }
}
