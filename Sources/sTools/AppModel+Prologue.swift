import AppKit
import Backdrop
import KeyRebinder
import NBBOverlay
import Prologue
import STDesign
import STPlatform
import SwiftUI

/// The first-launch introduction (spec 4): the app shows it in the main window and supplies everything that needs
/// the tools.
extension AppModel: PrologueHost {
    /// Shows the introduction at its saved step, or at `step`. Tools on at this moment stay on at its end.
    func beginPrologue(at step: PrologueStep? = nil) {
        endTrials()
        trials = TrialSession()
        toolsOnBeforePrologue = Set(ToolID.allCases.filter(isOn))
        prologue = PrologueModel(store: settings, host: self, startingAt: step)
    }

    /// Help ▸ Replay Introduction: from the greeting, whatever page is showing (spec D13).
    func replayIntroduction() {
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
        trialContent(trial)
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
        STMotion.animate(STMotion.page, reduce: theme.reduceMotion) {
            prologue = nil
        }
    }

    /// Undoes what the trials put in place for themselves only: the backdrop's stand-in window and the sample result.
    func endTrials() {
        trials.stopWatching()
        controller(for: .windowBackdrop, as: BackdropController.self)?.standIn = nil
        controller(for: .nbbOverlay, as: NBBOverlayController.self)?.sample = nil
    }
}

/// What the Prologue's companion steps say, gathered here (spec 4.2, steps 7 and 8).
enum PrologueCopy {
    static let karabinerDownload = URL(string: "https://karabiner-elements.pqrs.org/")!

    /// Ninjabrain Bot's API answered; Home says the same while the NBB Overlay is off.
    static let ninjabrainAnswers = "Ninjabrain Bot answers at localhost:52533."
    /// Ninjabrain Bot's API didn't answer; Home says the same.
    static let ninjabrainSilent = "Ninjabrain Bot isn\u{2019}t answering yet. Open it and turn on its API."

    static let ninjabrainReady = CompanionStatus(isReady: true, detail: ninjabrainAnswers)
    static let ninjabrainMissing = CompanionStatus(isReady: false, detail: ninjabrainSilent)

    static func karabiner(_ requirement: KarabinerRequirement) -> CompanionStatus {
        switch requirement {
        case .ready:
            CompanionStatus(isReady: true, detail: karabinerDetail(requirement))
        case .notInstalled, .versionTooOld:
            CompanionStatus(isReady: false, detail: karabinerDetail(requirement), actionTitle: "Get Karabiner-Elements\u{2026}")
        case .notRunning, .configUnreadable:
            CompanionStatus(isReady: false, detail: karabinerDetail(requirement), actionTitle: "Open Karabiner-Elements")
        }
    }

    /// Karabiner-Elements' state in a sentence, as the step and Home's Key Rebinder tile say it.
    static func karabinerDetail(_ requirement: KarabinerRequirement) -> String {
        switch requirement {
        case .ready: "Installed and running."
        case .notInstalled: "Karabiner-Elements isn\u{2019}t installed."
        case .notRunning: "Karabiner-Elements is installed but not running."
        case .versionTooOld(let found): "Karabiner-Elements \(found) is too old. Update to 16.0 or later."
        case .configUnreadable: "Open Karabiner-Elements once."
        }
    }
}

extension ToolID {
    init(_ trial: PrologueTrial) {
        switch trial {
        case .crosshair: self = .crosshair
        case .timerOverlay: self = .timerOverlay
        case .windowBackdrop: self = .windowBackdrop
        case .nbbOverlay: self = .nbbOverlay
        case .screenRecording: self = .screenRecording
        case .keyRebinder: self = .keyRebinder
        }
    }

    /// The tool's trial in the introduction; Custom Cursor has none yet (spec 5.7.4).
    var trial: PrologueTrial? {
        switch self {
        case .customCursor: nil
        case .crosshair: .crosshair
        case .windowBackdrop: .windowBackdrop
        case .nbbOverlay: .nbbOverlay
        case .screenRecording: .screenRecording
        case .keyRebinder: .keyRebinder
        case .timerOverlay: .timerOverlay
        }
    }
}
