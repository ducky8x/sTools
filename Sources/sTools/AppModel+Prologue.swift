import AppKit
import KeyRebinder
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
        switch companion {
        case .ninjabrainBot:
            return await pingNinjabrainBot() ? PrologueCopy.ninjabrainReady : PrologueCopy.ninjabrainMissing
        case .karabiner:
            let requirement = await evaluateKarabiner()
            lastKarabinerRequirement = requirement
            return PrologueCopy.karabiner(requirement)
        }
    }

    /// Karabiner-Elements' one action: get it when it's missing or too old, otherwise open it to finish its setup.
    func performAction(for companion: PrologueCompanion) {
        guard companion == .karabiner, let requirement = lastKarabinerRequirement else { return }
        switch requirement {
        case .notInstalled, .versionTooOld:
            NSWorkspace.shared.open(PrologueCopy.karabinerDownload)
        case .notRunning, .configUnreadable:
            NSWorkspace.shared.openApplication(at: KarabinerProbes.defaultAppURL, configuration: NSWorkspace.OpenConfiguration())
        case .ready:
            break
        }
    }

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

/// What the Prologue's companion steps say, gathered here (spec 4.2, steps 7 and 8).
enum PrologueCopy {
    static let karabinerDownload = URL(string: "https://karabiner-elements.pqrs.org/")!

    static let ninjabrainReady = CompanionStatus(isReady: true, detail: "Ninjabrain Bot answers at localhost:52533.")
    static let ninjabrainMissing = CompanionStatus(
        isReady: false, detail: "Nothing answers at localhost:52533 yet. Open Ninjabrain Bot and turn on its API.")

    static func karabiner(_ requirement: KarabinerRequirement) -> CompanionStatus {
        switch requirement {
        case .ready:
            CompanionStatus(isReady: true, detail: "Installed, running and new enough.")
        case .notInstalled:
            CompanionStatus(isReady: false, detail: "Karabiner-Elements isn\u{2019}t installed.", actionTitle: "Get Karabiner-Elements\u{2026}")
        case .notRunning:
            CompanionStatus(isReady: false, detail: "Karabiner-Elements is installed but not running.", actionTitle: "Open Karabiner-Elements")
        case .versionTooOld(let found):
            CompanionStatus(isReady: false, detail: "This Mac has Karabiner-Elements \(found); sTools needs 16.0 or later.",
                            actionTitle: "Get Karabiner-Elements\u{2026}")
        case .configUnreadable:
            CompanionStatus(isReady: false, detail: "Karabiner-Elements hasn\u{2019}t written its settings file yet.",
                            actionTitle: "Open Karabiner-Elements")
        }
    }
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
