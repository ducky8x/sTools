import STDesign
import SwiftUI

/// The page's preview (spec 5.6.3): the overlay in its current look with the live time. It draws the overlay's own
/// view from the controller's `content`, so the two can't differ, and shrinks the digits when the overlay is wider
/// than the plate.
///
/// It never moves: no pop, pulse or flashes (only the presenter moves the real overlay), and it has no timer of its
/// own. It redraws when `content` changes, at most once per shown change of the time, or when a setting does.
struct TimerPreviewPlate: View {
    let controller: TimerOverlayController

    /// The digit sizes tried, as fractions of the real one, until the overlay fits the plate.
    static let fitScales: [Double] = [1, 0.75, 0.5, 0.35]

    var body: some View {
        let content = controller.content
        STPlate {
            ViewThatFits(in: .horizontal) {
                TimerOverlayView(content: content, settings: settings(scaledBy: Self.fitScales[0]))
                TimerOverlayView(content: content, settings: settings(scaledBy: Self.fitScales[1]))
                TimerOverlayView(content: content, settings: settings(scaledBy: Self.fitScales[2]))
                TimerOverlayView(content: content, settings: settings(scaledBy: Self.fitScales[3]))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 112)
        }
    }

    /// The settings the overlay is drawn with, with the digits at `scale` of their size.
    private func settings(scaledBy scale: Double) -> TimerOverlaySettings {
        var settings = controller.settings
        settings.digitSize = max(10, Int((Double(settings.digitSize) * scale).rounded()))
        return settings
    }
}

/// What the run buttons under the preview allow (spec 5.6.3, plan decision 7): nothing without Accessibility; Start
/// from any phase; Pause while counting and Resume while paused; Cancel while a run is up; Test unless a countdown
/// runs or is paused.
struct TimerRunButtons: Equatable {
    var canStart: Bool
    /// "Pause" or "Resume".
    var pauseTitle: String
    var canPauseOrResume: Bool
    var canCancel: Bool
    var canTest: Bool

    init(phase: TimerPhase, isAvailable: Bool, canRunTest: Bool) {
        canStart = isAvailable
        pauseTitle = phase == .paused ? "Resume" : "Pause"
        canPauseOrResume = isAvailable && (phase == .counting || phase == .paused)
        canCancel = isAvailable && phase != .idle
        canTest = isAvailable && canRunTest
    }
}

/// Start, Pause / Resume, Cancel and Test, under the preview plate. Start and Test switch the tool on first through
/// the controller (plan decision 7).
struct TimerRunControls: View {
    let controller: TimerOverlayController

    var body: some View {
        let phase = controller.phase
        let buttons = TimerRunButtons(phase: phase, isAvailable: controller.isAvailable, canRunTest: controller.canRunTest)
        HStack(spacing: 10) {
            Button("Start") { controller.start() }
                .buttonStyle(STButtonStyle(.primary))
                .disabled(!buttons.canStart)
            Button(buttons.pauseTitle) {
                if phase == .paused { controller.resume() } else { controller.pause() }
            }
            .buttonStyle(STButtonStyle(.secondary))
            .disabled(!buttons.canPauseOrResume)
            Button("Cancel") { controller.cancel() }
                .buttonStyle(STButtonStyle(.secondary))
                .disabled(!buttons.canCancel)
            Spacer(minLength: 16)
            Button("Test") { controller.runTest() }
                .buttonStyle(STButtonStyle(.secondary))
                .disabled(!buttons.canTest)
                .help("A \(TimerOverlayController.testRunSeconds)-second run with the full pop-up, alarm and exit. The saved duration stays as it is.")
        }
    }
}
