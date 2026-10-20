import ScreenRecording
import STPlatform

extension AppModel {
    /// `HotkeyCenter` only knows the four switchable tools (`HotkeyTool`); Key Rebinder has no switch
    /// and isn't one of them.
    private static func toolID(for hotkeyTool: HotkeyTool) -> ToolID {
        switch hotkeyTool {
        case .nbbOverlay: .nbbOverlay
        case .windowBackdrop: .windowBackdrop
        case .crosshair: .crosshair
        case .screenRecording: .screenRecording
        }
    }

    func hotkeyToolStates() -> [HotkeyTool: Bool] {
        Dictionary(uniqueKeysWithValues: HotkeyTool.allCases.map { ($0, isOn(Self.toolID(for: $0))) })
    }

    /// A hotkey press resolves to a set of tool changes and/or a recording toggle (spec 6.1's toggle
    /// semantics are already resolved by `HotkeyCenter`/`HotkeyAction.resolve`; this just carries them
    /// out). Plays the stamp sound as the press's confirmation — the on-screen gold-seal HUD the spec
    /// also calls for isn't built yet: it needs a new transient overlay panel (sTools' own window may
    /// not even be visible when a global hotkey fires over Minecraft), which is a separate feature in
    /// its own right rather than a one-line addition here.
    func handleHotkeyEvent(_ event: HotkeyEvent) {
        switch event {
        case .setTool(let hotkeyTool, let isOn):
            setTool(Self.toolID(for: hotkeyTool), on: isOn)
        case .toggleRecording:
            guard let recording = controller(for: .screenRecording, as: ScreenRecordingController.self) else { break }
            // Switching on (when needed) goes through `requestEnable`, which keeps rule R10.
            recording.toggleRecording()
        }
        sound.play(.stamp)
    }
}
