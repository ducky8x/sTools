import Foundation

/// Where the user is in the first-run introduction (the Prologue). Stored as `appState.json`.
/// Deleting the file (what `ResetService` does) means "never started".
///
/// The Timer trial made the introduction 16 steps instead of 15 (spec 4). The file stays at version 1 and gains a
/// key instead, so a build from before the Timer trial still reads it rather than moving it aside and running the
/// introduction again: `prologueStep` keeps the index in the 15 steps such a build knows, and
/// `prologueStepWithTimerTrial` holds the index in today's 16. A file without the new key was written by such a
/// build, and its saved steps from the Timer trial's place on move up by one.
///
/// Revision 12 shows the Trials in sidebar order (Crosshair, Timer Overlay, NBB Overlay, Screen Recording, Window
/// Backdrop, Key Rebinder) instead of Crosshair, Timer Overlay, Window Backdrop, NBB Overlay, Screen Recording, Key
/// Rebinder. A saved index still names the same step in every build (`PrologueStep`'s raw values never change). The
/// file gains `trialsInSidebarOrder`; one without it was saved by a build that showed the old order, and only one of
/// its steps would resume past a trial not yet seen: Window Backdrop's, which came before NBB Overlay's and Screen
/// Recording's there and now comes after them. That step resumes at NBB Overlay's trial instead
/// (`step(fromOldTrialOrder:)`), so the user sees NBB Overlay, Screen Recording and then Window Backdrop.
public struct AppState: SettingsDocument {
    public static let name = "appState"
    public static let version = 1
    public static let defaultValue = AppState(prologueCompleted: false, prologueStep: 0)

    /// The Timer trial's index (step 10), where builds from before it had Window Backdrop's trial.
    public static let timerTrialIndex = 9
    /// Window Backdrop's trial's index, shown 13th since revision 12 and 11th before it.
    public static let backdropTrialIndex = 10
    /// NBB Overlay's trial's index, shown 11th since revision 12 and 12th before it.
    public static let nbbOverlayTrialIndex = 11

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

    /// A step index saved by a build that showed the Trials in the old order, in today's order: Window Backdrop's
    /// trial resumes at NBB Overlay's, which that build hadn't shown yet; every other step resumes where it was.
    public static func step(fromOldTrialOrder index: Int) -> Int {
        index == backdropTrialIndex ? nbbOverlayTrialIndex : index
    }

    private enum CodingKeys: String, CodingKey {
        case prologueCompleted
        /// The index in the 15 steps of builds from before the Timer trial.
        case stepBeforeTimerTrial = "prologueStep"
        case prologueStepWithTimerTrial
        /// Present (true) in a file saved by a build that shows the Trials in sidebar order.
        case trialsInSidebarOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prologueCompleted = try container.decodeIfPresent(Bool.self, forKey: .prologueCompleted) ?? false
        let step: Int
        if let saved = try container.decodeIfPresent(Int.self, forKey: .prologueStepWithTimerTrial) {
            step = saved
        } else {
            let saved = try container.decodeIfPresent(Int.self, forKey: .stepBeforeTimerTrial) ?? 0
            step = Self.step(fromBeforeTimerTrial: saved)
        }
        let inSidebarOrder = try container.decodeIfPresent(Bool.self, forKey: .trialsInSidebarOrder) ?? false
        prologueStep = inSidebarOrder ? step : Self.step(fromOldTrialOrder: step)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prologueCompleted, forKey: .prologueCompleted)
        try container.encode(Self.stepBeforeTimerTrial(prologueStep), forKey: .stepBeforeTimerTrial)
        try container.encode(prologueStep, forKey: .prologueStepWithTimerTrial)
        try container.encode(true, forKey: .trialsInSidebarOrder)
    }
}
