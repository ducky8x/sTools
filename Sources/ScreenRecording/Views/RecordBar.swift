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
        case .countingDown(let remaining):
            Button("Recording in \(remaining)\u{2026} Cancel") { controller.cancelCountdown() }
                .buttonStyle(STButtonStyle(.secondary))
        case .finishing:
            Button("Finishing\u{2026}") {}.buttonStyle(STButtonStyle(.secondary)).disabled(true)
        case .idle, .deciding:
            Button("Record") { Task { await controller.startRecording() } }
                .buttonStyle(STButtonStyle(.primary))
                .disabled(controller.phase == .deciding)
        }
    }

    private var detail: String {
        switch controller.phase {
        case .recording:
            var parts = [ByteCountFormatter.string(fromByteCount: controller.fileSize, countStyle: .file)]
            if controller.droppedFrames > 0 { parts.append("\(controller.droppedFrames) frames dropped") }
            return parts.joined(separator: " \u{00B7} ")
        case .countingDown: return "Get ready."
        case .finishing: return "Writing the file\u{2026}"
        case .deciding: return "Choose Save or Delete."
        case .idle: return controller.isEnabled ? "Ready." : "Record switches Screen Recording on first."
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

/// On Stop: Save with an optional name, or Delete (spec 5.4.4).
struct SaveDeleteSheet: View {
    @Bindable var controller: ScreenRecordingController
    @State private var name = ""
    @State private var confirmsDelete = false
    @Environment(\.stTheme) private var theme

    var body: some View {
        let finished = controller.finished
        VStack(alignment: .leading, spacing: 16) {
            Text("Save this recording?").stStyle(.sectionTitle).foregroundStyle(STColor.ink)
            if let finished {
                Text("\(RecordBar.clock(finished.seconds)) long\(finished.files.count > 1 ? ", in \(finished.files.count) files" : "").")
                    .stStyle(.body).foregroundStyle(theme.inkSecondary)
                if let explanation = finished.explanation {
                    Text(explanation).stStyle(.body).foregroundStyle(STColor.danger).fixedSize(horizontal: false, vertical: true)
                }
                if finished.droppedFrames > 0 {
                    Text("\(finished.droppedFrames) frames were dropped. If Game Mode was on, macOS may have lowered sTools\u{2019} priority; lower the frame rate or output size if this keeps happening.")
                        .stStyle(.caption).foregroundStyle(theme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            STTextField("Name (optional)", text: $name)
            Text(name.trimmingCharacters(in: .whitespaces).isEmpty
                 ? (finished?.files.first.map { "Without a name it\u{2019}s saved as \($0.deletingPathExtension().lastPathComponent).\(controller.options.fileType.fileExtension)." }
                    ?? "Without a name it\u{2019}s named by the date and time.")
                 : "Saved as \(RecordingFinisher.sanitizedName(name) ?? name).\(controller.options.fileType.fileExtension) in \((controller.options.folderPath as NSString).abbreviatingWithTildeInPath).")
                .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            HStack {
                Button("Delete\u{2026}") { confirmsDelete = true }.buttonStyle(STButtonStyle(.quiet))
                Spacer()
                Button("Save") { Task { await controller.save(name: name) } }
                    .buttonStyle(STButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.phase == .finishing)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(STColor.background)
        .interactiveDismissDisabled()
        .confirmationDialog("Delete this recording?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { controller.delete() }
        } message: {
            Text("The file is removed for good.")
        }
    }
}
