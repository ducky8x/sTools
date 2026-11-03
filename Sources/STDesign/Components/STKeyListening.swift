import SwiftUI

public extension View {
    /// Listens for one key while `isListening` is true, by the rules of `STShortcutRecorder` and `STKeyCapRecorder`:
    /// any known key, alone or with ⌃ ⌥ ⇧ ⌘, goes to `onKey`, Esc stops listening, and Delete gives `onKey` nil. A key
    /// `validate` refuses keeps it listening and is reported through `activity`, as a key cap reports it. One key, a
    /// click anywhere, another app coming to the front, the view being disabled or going away each stop it, and
    /// `isListening` turns false. It suits a control that records a key in place but starts listening from elsewhere,
    /// such as a menu's Set Key….
    func stListensForKey(_ isListening: Binding<Bool>, activity: Binding<STKeyCapActivity> = .constant(.idle),
                         validate: ((STShortcut) -> String?)? = nil,
                         onKey: @escaping (STShortcut?) -> Void) -> some View {
        modifier(STKeyListening(isListening: isListening, activity: activity,
                                validate: validate ?? STShortcutRecorderLogic.basicRejection, onKey: onKey))
    }
}

private struct STKeyListening: ViewModifier {
    @Binding var isListening: Bool
    @Binding var activity: STKeyCapActivity
    let validate: (STShortcut) -> String?
    let onKey: (STShortcut?) -> Void

    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @State private var model = STShortcutRecorderModel()
    @State private var monitor = STShortcutKeyMonitor()

    func body(content: Content) -> some View {
        content
            .onChange(of: isListening, initial: true) { _, listening in
                if listening && isEnabled { start() } else { stop() }
            }
            .onChange(of: model) { _, current in
                let now = STKeyCapActivity(current)
                if activity != now { activity = now }
                guard !current.isRecording else { return }
                monitor.stop()
                if isListening { isListening = false }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { stop() }
            }
            .onDisappear { stop() }
    }

    private func start() {
        guard !model.isRecording else { return }
        model.begin()
        monitor.start { event in
            switch event {
            case .flagsChanged(let modifiers):
                model.flagsChanged(modifiers)
            case .interrupted:
                stop()
            case .keyDown(let keyCode, let modifiers):
                switch model.keyDown(keyCode: keyCode, modifiers: modifiers, validate: validate) {
                case .commit(let recorded):
                    onKey(recorded)
                    sound.play(.click)
                case .clear:
                    onKey(nil)
                case .none:
                    break
                }
            }
        }
    }

    /// Stops listening. Turning the model idle ends the rest: the monitor stops and `isListening` turns false.
    private func stop() {
        if model.isRecording {
            model.cancel()
        } else {
            monitor.stop()
            if isListening { isListening = false }
        }
    }
}
