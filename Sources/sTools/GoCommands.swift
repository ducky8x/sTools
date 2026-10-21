import STDesign
import SwiftUI

/// The Go menu, plus Settings in the app menu in place of the standard (unused) settings command.
struct GoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            item(.settings, title: "Settings\u{2026}")
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { model.updater?.checkForUpdates() }
                .disabled(model.updater?.isAvailable != true)
        }
        CommandMenu("Go") {
            ForEach(GoCommand.menu, id: \.self) { command in
                item(command, title: command.title)
                if command == .tool(.keyRebinder) || command == .settings { Divider() }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Replay Introduction") { model.replayIntroduction() }
            Button("Copy Diagnostics") { model.copyDiagnostics() }
        }
    }

    @ViewBuilder
    private func item(_ command: GoCommand, title: String) -> some View {
        Button(title) { model.perform(command) }
            .keyboardShortcut(KeyEquivalent(command.shortcutKey), modifiers: .command)
            .disabled(isDisabled(command))
    }

    private func isDisabled(_ command: GoCommand) -> Bool {
        if let flow = model.prologue?.flow {
            switch command {
            case .back: return !flow.canGoBack
            case .forward: return !flow.canMoveOn || flow.isLastStep
            default: return true
            }
        }
        return switch command {
        case .back: !model.canGoBack
        case .forward: !model.canGoForward
        default: false
        }
    }
}
