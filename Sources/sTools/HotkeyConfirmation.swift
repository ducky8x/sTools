import ScreenRecording
import STPlatform

/// What one hotkey press actually did, and the one line the confirmation shows for it (spec 6.1).
enum HotkeyConfirmation {
    enum Effect: Equatable {
        /// The tool is now on or off.
        case tool(ToolID, isOn: Bool)
        /// The tool was asked to switch on but stayed off: it needs Accessibility (rule R10).
        case needsAccessibility(ToolID)
        /// A start is under way and its sources are still starting, so nothing is recorded yet; "Recording started"
        /// follows once the first frame is in the file.
        case recordingStarting
        /// The writer put the recording's first frame in the file. Shown then, not at the press.
        case recordingStarted
        /// A start the key made ended after the press without a recording, for this reason ("the disk is almost full"),
        /// and Screen Recording switched off, so the line says both, as the stop's does.
        case recordingCouldNotStart(String)
        /// Recording starts once the countdown (Screen Recording ▸ Advanced) runs out.
        case recordingCountdown(seconds: Int)
        /// The recording stopped, which switched Screen Recording off too, so the line says both, as Timer Overlay's
        /// cancel says "Timer Overlay off" (spec 5.4.4, 6.1).
        case recordingStopped
        /// A start was canceled before anything was written (the sources were starting, or the countdown ran), and
        /// Screen Recording switched off, so the line says both, as the stop's does.
        case recordingCanceled
        /// The last recording is still being finished, so the press changed nothing.
        case recordingFinishing
        /// The last recording waits for Save or Delete in its panel, so the press only brought that forward.
        case recordingAwaitingDecision
        /// Nothing started: Screen Recording needs the Screen & System Audio Recording permission.
        case recordingNeedsPermission
    }

    /// Whether the press changed anything. Only then does the seal stamp: a gold check beside
    /// "Crosshair needs Accessibility" alone would claim a success that didn't happen.
    static func changedSomething(_ effects: [Effect]) -> Bool {
        effects.contains { effect in
            switch effect {
            case .tool, .recordingStarted, .recordingCountdown, .recordingStopped, .recordingCanceled: true
            case .needsAccessibility, .recordingStarting, .recordingCouldNotStart, .recordingFinishing,
                 .recordingAwaitingDecision, .recordingNeedsPermission: false
            }
        }
    }

    /// The effects in press order, joined by a middle dot: "Crosshair on · NBB Overlay on".
    static func summary(_ effects: [Effect]) -> String {
        effects.map(phrase).joined(separator: " \u{00B7} ")
    }

    static func phrase(_ effect: Effect) -> String {
        switch effect {
        case .tool(let tool, let isOn): "\(tool.title) \(isOn ? "on" : "off")"
        case .needsAccessibility(let tool): "\(tool.title) needs Accessibility"
        case .recordingStarting: "Starting the recording\u{2026}"
        case .recordingStarted: "Recording started"
        case .recordingCouldNotStart(let reason): "Recording couldn\u{2019}t start: \(reason) \u{00B7} \(screenRecordingOff)"
        case .recordingCountdown(let seconds): "Recording starts in \(CountText.of(seconds, "second"))"
        case .recordingStopped: "Recording stopped \u{00B7} \(screenRecordingOff)"
        case .recordingCanceled: "Recording canceled \u{00B7} \(screenRecordingOff)"
        case .recordingFinishing: "Still finishing the last recording"
        case .recordingAwaitingDecision: "Save or delete the last recording first"
        case .recordingNeedsPermission: "Screen Recording needs Screen & System Audio Recording"
        }
    }

    /// The stop, a canceled start and a failed one all switch Screen Recording off, and their lines end saying so.
    private static var screenRecordingOff: String { phrase(.tool(.screenRecording, isOn: false)) }

    /// The line for one press of Screen Recording's key, from what the press did (`toggleRecording()` says so as it
    /// returns, before the start or the stop has finished). A start never says "Recording started" here: that waits
    /// for its first frame (`recordingStartEffect`). While its sources start, the press says the recording is
    /// starting; with them already running, the first frame follows at once and the press has no line of its own.
    static func recordingEffect(_ press: ScreenRecordingController.KeyPress) -> Effect? {
        switch press {
        case .starting(let waitsForSources): waitsForSources ? .recordingStarting : nil
        case .countdown(let seconds): .recordingCountdown(seconds: seconds)
        case .stopped: .recordingStopped
        case .canceled: .recordingCanceled
        case .awaitingDecision: .recordingAwaitingDecision
        case .finishing: .recordingFinishing
        case .couldNotSwitchOn: .needsAccessibility(.screenRecording)
        case .needsPermission: .recordingNeedsPermission
        }
    }

    /// The line once a start the key made has turned out: "Recording started" as its first frame is in the file, or
    /// why it couldn't start.
    static func recordingStartEffect(_ outcome: ScreenRecordingController.KeyStartOutcome) -> Effect {
        switch outcome {
        case .started: .recordingStarted
        case .failed(let reason): .recordingCouldNotStart(reason)
        }
    }
}
