import Prologue
import STDesign
import STPlatform
import SwiftUI

/// The first-launch introduction (spec 4): the app shows it in the main window and supplies everything that needs
/// the tools.
extension AppModel: PrologueHost {
    /// Shows the introduction at its saved step, or at `step`. Tools on at this moment stay on at its end.
    func beginPrologue(at step: PrologueStep? = nil) {
        toolsOnBeforePrologue = Set(ToolID.allCases.filter(isOn))
        prologue = PrologueModel(store: settings, host: self, startingAt: step)
    }

    /// Help ▸ Replay Introduction: from the greeting, whatever page is showing (spec D13).
    func replayIntroduction() {
        endTrials()
        beginPrologue(at: .greeting)
    }

    // MARK: PrologueHost

    func check(_ companion: PrologueCompanion) async -> CompanionStatus {
        CompanionStatus(isReady: false)
    }

    func performAction(for companion: PrologueCompanion) {}

    func trial(_ trial: PrologueTrial) -> TrialContent {
        TrialContent(items: { [] }, completed: { [] }, controls: { AnyView(EmptyView()) })
    }

    func toolsToSwitchOff() -> [PrologueTrial] {
        ToolID.allCases
            .filter { $0.hasSwitch && isOn($0) && !toolsOnBeforePrologue.contains($0) }
            .compactMap(\.trial)
    }

    func switchOff(_ tool: PrologueTrial) {
        setTool(ToolID(tool), on: false)
    }

    func relaunch() {
        AppRelauncher.relaunch()
    }

    func prologueDidEnd(_ outcome: PrologueFlow.Outcome) {
        endTrials()
        if outcome == .skipped {
            for tool in toolsToSwitchOff() { switchOff(tool) }
        }
        history = NavigationHistory(start: .home)
        withAnimation(STMotion.resolve(STMotion.page, reduce: theme.reduceMotion)) {
            prologue = nil
        }
    }

    /// Undoes what the trials put in place for themselves only.
    func endTrials() {}
}

extension ToolID {
    init(_ trial: PrologueTrial) {
        switch trial {
        case .crosshair: self = .crosshair
        case .windowBackdrop: self = .windowBackdrop
        case .nbbOverlay: self = .nbbOverlay
        case .screenRecording: self = .screenRecording
        case .keyRebinder: self = .keyRebinder
        }
    }

    var trial: PrologueTrial {
        switch self {
        case .crosshair: .crosshair
        case .windowBackdrop: .windowBackdrop
        case .nbbOverlay: .nbbOverlay
        case .screenRecording: .screenRecording
        case .keyRebinder: .keyRebinder
        }
    }
}
