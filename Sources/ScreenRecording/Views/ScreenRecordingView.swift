import STDesign
import STPlatform
import SwiftUI

/// Everything below Screen Recording's page header (spec 5.4).
public struct ScreenRecordingView: View {
    @Bindable private var controller: ScreenRecordingController
    @State private var selection: UUID?
    @State private var isAppeared = false
    @Environment(\.stTheme) private var theme
    @Environment(\.stWindowIsVisible) private var windowIsVisible

    public init(controller: ScreenRecordingController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if controller.screenRecordingPermission != .granted {
                STRequirementStrip(
                    kind: .warning,
                    message: "Screen Recording needs the Screen & System Audio Recording permission to see Minecraft and your sources.",
                    actionTitle: "Allow\u{2026}") {
                        Task { await controller.allowScreenRecording() }
                    }
            }
            ForEach(Array(controller.notes.enumerated()), id: \.offset) { _, note in
                STRequirementStrip(kind: .warning, message: note)
            }
            if !controller.notes.isEmpty {
                Button("Clear Notes") { controller.clearNotes() }.buttonStyle(STButtonStyle(.quiet))
            }

            STPlate {
                VStack(alignment: .leading, spacing: 14) {
                    RecordingCanvasEditor(controller: controller, selection: $selection)
                    RecordBar(controller: controller)
                    Text("The rules ask that the hotbar, \u{201C}Game Paused\u{201D}, toasts, the timer and chat stay visible, and to \u{201C}try to avoid excessive overlays over the game itself\u{201D} (A.2.9, A.2.10).")
                        .stStyle(.caption)
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }

            RecordingSourcesSection(controller: controller, selection: $selection)
            RecordingSoundSection(controller: controller)
            RecordingSettingsSection(controller: controller)
        }
        // The live preview only renders while it can be seen: not while the window is minimized, closed or behind
        // the game.
        .onAppear {
            isAppeared = true
            controller.setPreviewVisible(windowIsVisible)
        }
        .onDisappear {
            isAppeared = false
            controller.setPreviewVisible(false)
        }
        .onChange(of: windowIsVisible) { _, visible in controller.setPreviewVisible(isAppeared && visible) }
        // The Save/Delete question after Stop is the controller's own floating panel (`RecordingDecisionPanel`), so
        // it shows whichever page is open, with the window closed and with Minecraft in front.
    }
}
