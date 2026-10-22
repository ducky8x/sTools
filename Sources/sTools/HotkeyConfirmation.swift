import ScreenRecording

/// What one hotkey press actually did, and the one line the confirmation shows for it (spec 6.1).
enum HotkeyConfirmation {
    enum Effect: Equatable {
        /// The tool is now on or off.
        case tool(ToolID, isOn: Bool)
        /// The tool was asked to switch on but stayed off: it needs Accessibility (rule R10).
        case needsAccessibility(ToolID)
        case recordingStarted
        /// Recording starts once the countdown (Screen Recording ▸ Advanced) runs out.
        case recordingCountdown(seconds: Int)
        case recordingStopped
        /// A start was canceled before anything was written (the sources were starting, or the countdown ran), and
        /// Screen Recording switched off.
        case recordingCanceled
        /// The last recording is still being finished, so the press changed nothing.
        case recordingFinishing
        /// The last recording waits for Save or Delete in its panel, so the press only brought that forward.
        case recordingAwaitingDecision
    }

    /// Whether the press changed anything. Only then does the seal stamp: a gold check beside
    /// "Crosshair needs Accessibility" alone would claim a success that didn't happen.
    static func changedSomething(_ effects: [Effect]) -> Bool {
        effects.contains { effect in
            switch effect {
            case .tool, .recordingStarted, .recordingCountdown, .recordingStopped, .recordingCanceled: true
            case .needsAccessibility, .recordingFinishing, .recordingAwaitingDecision: false
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
        case .recordingStarted: "Recording started"
        case .recordingCountdown(let seconds): "Recording starts in \(seconds) seconds"
        case .recordingStopped: "Recording stopped"
        case .recordingCanceled: "Recording canceled"
        case .recordingFinishing: "Still finishing the last recording"
        case .recordingAwaitingDecision: "Save or delete the last recording first"
        }
    }

    /// The line for one press of Screen Recording's key, from what the press did (`toggleRecording()` says so as
    /// it returns, before the start or the stop has finished).
    static func recordingEffect(_ press: ScreenRecordingController.KeyPress) -> Effect {
        switch press {
        case .started: .recordingStarted
        case .countdown(let seconds): .recordingCountdown(seconds: seconds)
        case .stopped: .recordingStopped
        case .canceled: .recordingCanceled
        case .awaitingDecision: .recordingAwaitingDecision
        case .finishing: .recordingFinishing
        case .couldNotSwitchOn: .needsAccessibility(.screenRecording)
        }
    }
}
