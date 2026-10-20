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

/// The tools tried in the Trials, simplest first (spec D2). The four with a switch are also what the Finale
/// switches off.
public enum PrologueTrial: String, CaseIterable, Sendable {
    case crosshair, windowBackdrop, nbbOverlay, screenRecording, keyRebinder
}

/// The two companion apps set up in the Preparations (spec R6).
public enum PrologueCompanion: String, CaseIterable, Sendable {
    case ninjabrainBot, karabiner
}

/// The 15 steps, in order. The raw value is the index saved in `AppState.prologueStep`.
public enum PrologueStep: Int, CaseIterable, Sendable, Identifiable {
    case greeting
    case accessibility, screenRecording, appAudio, microphone, camera, ninjabrainBot, karabiner
    case crosshairTrial, backdropTrial, nbbOverlayTrial, recordingTrial, keyRebinderTrial
    case youreSet, openSTools

    public var id: Int { rawValue }

    /// 1-based, as shown in "Step 4 of 15".
    public var number: Int { rawValue + 1 }

    public static let count = allCases.count

    public var part: ProloguePart {
        switch self {
        case .greeting: .welcome
        case .accessibility, .screenRecording, .appAudio, .microphone, .camera, .ninjabrainBot, .karabiner: .preparations
        case .crosshairTrial, .backdropTrial, .nbbOverlayTrial, .recordingTrial, .keyRebinderTrial: .trials
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
