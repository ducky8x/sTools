import STDesign
import STPlatform
import SwiftUI

/// Everything below Screen Recording's page header (spec 5.4).
public struct ScreenRecordingView: View {
    @Bindable private var controller: ScreenRecordingController
    @State private var selection: UUID?
    @Environment(\.stTheme) private var theme

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
        .onAppear { controller.setPreviewVisible(true) }
        .onDisappear { controller.setPreviewVisible(false) }
        .sheet(isPresented: Binding(get: { controller.phase == .deciding }, set: { _ in })) {
            // A sheet is a window of its own, so it gets its own motion root.
            SaveDeleteSheet(controller: controller).stMotionRoot(theme)
        }
    }
}
