import STPlatform
import SwiftUI

/// What a companion app's check found (spec 4.2, steps 7 and 8).
public struct CompanionStatus: Equatable, Sendable {
    public var isReady: Bool
    /// One sentence on what is missing; nil when ready.
    public var detail: String?
    /// The one action that fixes it now ("Get Karabiner-Elements…"); nil when there is none.
    public var actionTitle: String?

    public init(isReady: Bool, detail: String? = nil, actionTitle: String? = nil) {
        self.isReady = isReady
        self.detail = detail
        self.actionTitle = actionTitle
    }

    public static let ready = CompanionStatus(isReady: true)
}

/// One trial's live parts, built by the app, which can see the tools (the Prologue can't).
@MainActor
public struct TrialContent {
    /// The checklist items as they stand now. Read inside a view body, so observable state it reads updates it.
    public var items: () -> [ChecklistItem]
    /// The ids of the items done right now; they tick as soon as they appear here.
    public var completed: () -> Set<String>
    /// The tool's real controls: its switch and settings.
    public var controls: () -> AnyView
    /// Called each time the step appears and disappears.
    public var onAppear: () -> Void
    public var onDisappear: () -> Void

    public init(items: @escaping () -> [ChecklistItem], completed: @escaping () -> Set<String>,
                controls: @escaping () -> AnyView,
                onAppear: @escaping () -> Void = {}, onDisappear: @escaping () -> Void = {}) {
        self.items = items
        self.completed = completed
        self.controls = controls
        self.onAppear = onAppear
        self.onDisappear = onDisappear
    }
}

/// Everything the Prologue needs from the app. The app target is the only place that sees every tool, so it
/// supplies statuses, trials and tool switches; the Prologue drives them.
@MainActor
public protocol PrologueHost: AnyObject {
    var permissions: PermissionCenter { get }

    /// One check of a companion app; the Prologue repeats it every second while its step shows.
    func check(_ companion: PrologueCompanion) async -> CompanionStatus
    /// Runs the companion's current action (the one named by its status's `actionTitle`).
    func performAction(for companion: PrologueCompanion)

    func trial(_ trial: PrologueTrial) -> TrialContent

    /// Tools switched on since the Prologue began, in sidebar order: the Finale switches them off.
    func toolsToSwitchOff() -> [PrologueTrial]
    func switchOff(_ tool: PrologueTrial)

    /// Quits and opens sTools again; the Prologue resumes at the saved step.
    func relaunch()

    /// The Prologue finished or was skipped; its progress is already saved.
    func prologueDidEnd(_ outcome: PrologueFlow.Outcome)
}
