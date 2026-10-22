import AppKit
import STDesign
import SwiftUI

/// Record / Stop with elapsed time and file size (spec 5.4.4), and what the last recording was saved as.
struct RecordBar: View {
    @Bindable var controller: ScreenRecordingController
    @Environment(\.stTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                button
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.clock(controller.elapsedSeconds))
                        .font(STFont.figures(22))
                        .foregroundStyle(controller.isRecording ? STColor.ink : theme.inkTertiary)
                        .accessibilityLabel("Elapsed \(Self.clock(controller.elapsedSeconds))")
                    Text(detail).stStyle(.caption).foregroundStyle(theme.inkTertiary)
                }
                Spacer()
            }
            if let saved = controller.lastSaved, let first = saved.files.first {
                HStack(spacing: 10) {
                    Text("Saved \u{201C}\(first.lastPathComponent)\u{201D}\(saved.files.count > 1 ? " and \(saved.files.count - 1) more" : "").")
                        .stStyle(.body).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    Button("Show in Finder") { controller.revealLastSaved() }.buttonStyle(STButtonStyle(.quiet))
                }
                ForEach(saved.problems, id: \.self) { problem in
                    Text(problem).stStyle(.caption).foregroundStyle(STColor.danger)
                }
            }
        }
    }

    @ViewBuilder private var button: some View {
        switch controller.phase {
        case .recording:
            Button("Stop") { Task { await controller.stopRecording(explanation: nil) } }
                .buttonStyle(STButtonStyle(.primary))
                .keyboardShortcut(".", modifiers: .command)
        case .starting:
            // Nothing is written yet; canceling switches the tool off, as the key does.
            Button("Starting\u{2026} Cancel") { controller.cancelStart() }
                .buttonStyle(STButtonStyle(.secondary))
        case .countingDown(let remaining):
            Button("Recording in \(remaining)\u{2026} Cancel") { controller.cancelStart() }
                .buttonStyle(STButtonStyle(.secondary))
        case .finishing:
            Button("Finishing\u{2026}") {}.buttonStyle(STButtonStyle(.secondary)).disabled(true)
        case .deciding:
            // The question is in a panel of its own; this brings it forward, over this window.
            Button("Save or Delete\u{2026}") { controller.presentDecision() }
                .buttonStyle(STButtonStyle(.secondary))
        case .idle:
            Button("Record") { Task { await controller.startRecording() } }
                .buttonStyle(STButtonStyle(.primary))
                // Without the permission nothing would be recorded; the strip at the top of the page offers Allow….
                .disabled(!canRecord)
        }
    }

    private var detail: String {
        switch controller.phase {
        case .recording:
            var parts = [ByteCountFormatter.string(fromByteCount: controller.fileSize, countStyle: .file)]
            if controller.droppedFrames > 0 { parts.append("\(controller.droppedFrames) frames dropped") }
            return parts.joined(separator: " \u{00B7} ")
        case .starting: return "Starting the sources."
        case .countingDown: return "Get ready."
        case .finishing: return "Writing the file\u{2026}"
        case .deciding: return "Choose Save or Delete. Screen Recording switches off after."
        case .idle:
            if !canRecord { return "Allow Screen & System Audio Recording to record." }
            return controller.isEnabled ? "Ready. Stopping switches Screen Recording off." : "Record switches Screen Recording on first."
        }
    }

    private var canRecord: Bool { controller.screenRecordingPermission == .granted }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
