import STPlatform

/// The four parts of the introduction (spec 4.2), named in the progress line.
public enum ProloguePart: Int, CaseIterable, Sendable {
    case welcome, preparations, trials, finale

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .preparations: "Preparations"
        case .trials: "Trials"
        case .finale: "Finale"
        }
    }
}

/// The tools tried in the Trials, in sidebar order (spec 4.2, revision 12). The five with a switch are also what the
/// Finale switches off.
public enum PrologueTrial: String, CaseIterable, Sendable {
    case crosshair, timerOverlay, nbbOverlay, screenRecording, windowBackdrop, keyRebinder
}

/// The two companion apps set up in the Preparations (spec R6).
public enum PrologueCompanion: String, CaseIterable, Sendable {
    case ninjabrainBot, karabiner
}

/// The 16 steps, in the order they're shown (`allCases`); the Trials follow the sidebar (spec 4.2, revision 12).
///
/// The raw value is the index saved in `AppState.prologueStep`: it names the step, not its place, so it never
/// changes and every build reads the same step from a saved index. Earlier builds showed the Trials as Crosshair,
/// Timer Overlay, Window Backdrop, NBB Overlay, Screen Recording, Key Rebinder, which is why Window Backdrop's index
/// (`AppState.backdropTrialIndex`) comes before NBB Overlay's; `AppState` resumes a step those builds saved there at
/// NBB Overlay's trial, so no trial goes unseen. The Timer trial is index 9 (`AppState.timerTrialIndex`), new after
/// builds that had 15 steps.
public enum PrologueStep: Int, CaseIterable, Sendable, Identifiable {
    case greeting = 0
    case accessibility = 1, screenRecording = 2, appAudio = 3, microphone = 4, camera = 5, ninjabrainBot = 6, karabiner = 7
    case crosshairTrial = 8, timerTrial = 9, nbbOverlayTrial = 11, recordingTrial = 12, backdropTrial = 10, keyRebinderTrial = 13
    case youreSet = 14, openSTools = 15

    public var id: Int { rawValue }

    /// 1-based place in the order shown, as in "Step 4 of 16". Not the saved index (`rawValue`).
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public static let count = allCases.count

    /// The step shown after this one; nil after the last.
    public var following: PrologueStep? {
        let index = number
        return index < Self.count ? Self.allCases[index] : nil
    }

    /// The step shown before this one; nil before the greeting.
    public var preceding: PrologueStep? {
        let index = number - 2
        return index >= 0 ? Self.allCases[index] : nil
    }

    public var part: ProloguePart {
        switch self {
        case .greeting: .welcome
        case .accessibility, .screenRecording, .appAudio, .microphone, .camera, .ninjabrainBot, .karabiner: .preparations
        case .crosshairTrial, .timerTrial, .backdropTrial, .nbbOverlayTrial, .recordingTrial, .keyRebinderTrial: .trials
        case .youreSet, .openSTools: .finale
        }
    }

    /// The permission a Preparations step sets up.
    public var permission: Permission? {
        switch self {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        case .appAudio: .appAudio
        case .microphone: .microphone
        case .camera: .camera
        default: nil
        }
    }

    public var companion: PrologueCompanion? {
        switch self {
        case .ninjabrainBot: .ninjabrainBot
        case .karabiner: .karabiner
        default: nil
        }
    }

    public var trial: PrologueTrial? {
        switch self {
        case .crosshairTrial: .crosshair
        case .timerTrial: .timerOverlay
        case .backdropTrial: .windowBackdrop
        case .nbbOverlayTrial: .nbbOverlay
        case .recordingTrial: .screenRecording
        case .keyRebinderTrial: .keyRebinder
        default: nil
        }
    }

    /// The step at a saved index; anything out of range starts over at the greeting.
    public init(savedIndex: Int) {
        self = PrologueStep(rawValue: savedIndex) ?? .greeting
    }
}

/// Which way the last page turn went: forward pages arrive from the right, backward ones from the left.
public enum PageDirection: Sendable, Equatable {
    case forward, backward
}
