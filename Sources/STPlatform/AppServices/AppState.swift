import Foundation

/// Where the user is in the first-run introduction (the Prologue). Stored as `appState.json`.
/// Deleting the file (what `ResetService` does) means "never started".
///
/// The Timer trial made the introduction 16 steps instead of 15 (spec 4). The file stays at version 1 and gains a
/// key instead, so a build from before the Timer trial still reads it rather than moving it aside and running the
/// introduction again: `prologueStep` keeps the index in the 15 steps such a build knows, and
/// `prologueStepWithTimerTrial` holds the index in today's 16. A file without the new key was written by such a
/// build, and its saved steps from the Timer trial's place on move up by one.
public struct AppState: SettingsDocument {
    public static let name = "appState"
    public static let version = 1
    public static let defaultValue = AppState(prologueCompleted: false, prologueStep: 0)

    /// The Timer trial's index (step 10), where builds from before it had Window Backdrop's trial.
    public static let timerTrialIndex = 9

    /// True once the user finished or skipped the introduction.
    public var prologueCompleted: Bool
    /// Index of the step to resume at while the introduction is unfinished, in today's 16 steps.
    public var prologueStep: Int

    public init(prologueCompleted: Bool = false, prologueStep: Int = 0) {
        self.prologueCompleted = prologueCompleted
        self.prologueStep = prologueStep
    }

    /// A step index saved by a build from before the Timer trial, in today's steps.
    public static func step(fromBeforeTimerTrial index: Int) -> Int {
        index >= timerTrialIndex ? index + 1 : index
    }

    /// Today's step index as a build from before the Timer trial counts it. The Timer trial itself becomes the step
    /// after it there, Window Backdrop's trial.
    public static func stepBeforeTimerTrial(_ index: Int) -> Int {
        index > timerTrialIndex ? index - 1 : index
    }

    private enum CodingKeys: String, CodingKey {
        case prologueCompleted
        /// The index in the 15 steps of builds from before the Timer trial.
        case stepBeforeTimerTrial = "prologueStep"
        case prologueStepWithTimerTrial
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prologueCompleted = try container.decodeIfPresent(Bool.self, forKey: .prologueCompleted) ?? false
        if let step = try container.decodeIfPresent(Int.self, forKey: .prologueStepWithTimerTrial) {
            prologueStep = step
        } else {
            let saved = try container.decodeIfPresent(Int.self, forKey: .stepBeforeTimerTrial) ?? 0
            prologueStep = Self.step(fromBeforeTimerTrial: saved)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prologueCompleted, forKey: .prologueCompleted)
        try container.encode(Self.stepBeforeTimerTrial(prologueStep), forKey: .stepBeforeTimerTrial)
        try container.encode(prologueStep, forKey: .prologueStepWithTimerTrial)
    }
}
