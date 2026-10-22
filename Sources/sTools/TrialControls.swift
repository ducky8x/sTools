import AVKit
import Combine
import KeyRebinder
import ScreenRecording
import STDesign
import STPlatform
import SwiftUI

/// A tool's real controls inside its trial: its switch (or, for the Key Rebinder, its profile menu), the
/// Accessibility strip when it's missing, then the same settings as its page, without sTools hotkeys. Timer
/// Overlay's trial adds its own Start-timer key under the switch.
struct TrialToolControls: View {
    let model: AppModel
    let tool: ToolID

    private enum Copy {
        static let profile = "Profile"
        static let allow = "Allow\u{2026}"
        static func needsAccessibility(_ tool: ToolID) -> String { "\(tool.title) needs Accessibility to find the Minecraft window." }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tool.hasSwitch {
                STSettingsRow(tool.title) {
                    STSwitch(isOn: model.switchBinding(tool), label: tool.title)
                        .disabled(!model.canSwitch(tool))
                }
            } else if let keyRebinder = model.keyRebinder {
                STSettingsRow(Copy.profile) {
                    KeyRebinderProfileMenu(controller: keyRebinder)
                }
            }
            if tool == .timerOverlay {
                TrialStartTimerKeyRow(model: model)
            }
            if tool.requiresAccessibility && !model.accessibilityGranted {
                STRequirementStrip(kind: .warning, message: Copy.needsAccessibility(tool), actionTitle: Copy.allow) {
                    Task { await model.allowAccessibility() }
                }
                .padding(.top, 12)
            }
            ToolContent(model: model, tool: tool, isTrial: true)
                .padding(.top, 18)
        }
        .pollsPermissions(model.permissions, showing: tool.permissionsShown, when: tool.requiresAccessibility)
    }
}

/// The Timer trial's own Start-timer key (spec 5.6.9). The page's Set in Hotkeys\u{2026} is hidden in the trials, so
/// the key is recorded right here as a Home \u{25B8} Hotkeys hotkey whose only action starts the timer.
struct TrialStartTimerKeyRow: View {
    let model: AppModel

    private enum Copy {
        static let title = "Start-timer key"
    }

    var body: some View {
        STSettingsRow(Copy.title) {
            STShortcutRecorder(shortcut: shortcutBinding, label: Copy.title,
                               validate: { TrialStartTimerKey.refusal(for: $0.hotkeyCombo, in: model.hotkeys) })
                .frame(width: 200)
        }
    }

    private var shortcutBinding: Binding<STShortcut?> {
        Binding(
            get: { TrialStartTimerKey.own(in: model.hotkeys.bindings)?.combo.asSTShortcut },
            set: { TrialStartTimerKey.set($0?.hotkeyCombo, in: model) })
    }
}

/// The Start-timer key the Timer trial sets: the first hotkey whose only action starts the timer.
@MainActor
enum TrialStartTimerKey {
    static func own(in bindings: [HotkeyBinding]) -> HotkeyBinding? {
        bindings.first { $0.actions == [.startTimer] }
    }

    /// Sets the key: changes that hotkey's key, or adds it at the end of the list. While Hotkeys are off it asks
    /// before turning them on, and keeps nothing if the answer is no. Nil clears the key.
    static func set(_ combo: HotkeyCombo?, in model: AppModel) {
        let center = model.hotkeys
        switch (combo, own(in: center.bindings)) {
        case (let combo?, let own?):
            guard turnOnHotkeys(model) else { return }
            center.update(own.id, combo: combo)
        case (let combo?, nil):
            guard turnOnHotkeys(model) else { return }
            center.add(combo: combo, actions: [.startTimer])
        case (nil, let own?):
            center.remove(own.id)
        case (nil, nil):
            break
        }
    }

    /// Why the recorder refuses `combo`, with the same rules as Home's editor. Nil when it's fine.
    static func refusal(for combo: HotkeyCombo, in center: HotkeyCenter) -> String? {
        guard let conflict = center.conflict(for: combo, excluding: own(in: center.bindings)?.id), conflict != .noActions else {
            return nil
        }
        return HotkeyWording.conflictText(conflict, combo: combo, inList: false)
    }

    private static func turnOnHotkeys(_ model: AppModel) -> Bool {
        if model.hotkeys.isEnabled { return true }
        guard model.confirmTurningOnHotkeys() else { return false }
        model.hotkeys.isEnabled = true
        return true
    }
}

/// The Screen Recording trial's 5-second test: one button records and saves it like any recording (spec D7), then
/// the clip plays right here.
struct TestRecordingPlate: View {
    let model: AppModel
    let recording: ScreenRecordingController
    let session: TrialSession

    private enum Copy {
        static let title = "5-second test"
        static let record = "Record a 5-Second Test"
        static let again = "Record Again"
        static let hint = "Records the canvas for five seconds and saves it in your recordings folder."
        static func recording(_ seconds: Int) -> String { "Recording\u{2026} \(seconds) s" }
        static let failed = "The test couldn\u{2019}t record. Check the notes below."
    }

    @Environment(\.stTheme) private var theme
    @State private var failed = false

    private var clip: URL? { AppModel.testClip(recording, session) }

    var body: some View {
        STPlate {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Text(Copy.title)
                        .stStyle(.sectionTitle)
                        .foregroundStyle(STColor.ink)
                    Spacer(minLength: 8)
                    Button(buttonTitle, action: record)
                        .buttonStyle(STButtonStyle(.secondary))
                        .disabled(session.isRecordingTest || recording.phase != .idle || !model.canSwitch(.screenRecording))
                }
                Text(failed ? Copy.failed : Copy.hint)
                    .stStyle(.caption)
                    .foregroundStyle(failed ? STColor.danger : theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let clip {
                    TrialClipPlayer(url: clip) { session.didPlayBack = true }
                        .id(clip)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.opacity)
                }
            }
            .padding(16)
            .stAnimation(STMotion.standard, value: clip)
        }
    }

    private var buttonTitle: String {
        if session.isRecordingTest { return Copy.recording(Int(recording.elapsedSeconds.rounded(.down))) }
        return clip == nil ? Copy.record : Copy.again
    }

    private func record() {
        session.isRecordingTest = true
        failed = false
        Task {
            let saved = await recording.recordTest(for: .seconds(5))
            failed = !saved
            session.isRecordingTest = false
        }
    }
}

/// AVKit's player with inline controls; reports the first time it plays.
private struct TrialClipPlayer: View {
    let onPlay: () -> Void
    @State private var player: AVPlayer

    init(url: URL, onPlay: @escaping () -> Void) {
        self.onPlay = onPlay
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onReceive(player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main)) { status in
                if status == .playing { onPlay() }
            }
            .onDisappear { player.pause() }
            .accessibilityLabel("The test recording")
    }
}
