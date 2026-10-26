import Foundation

/// A privacy permission sTools asks the user for.
public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording
    case appAudio
    case microphone
    case camera

    /// The name macOS uses (or, for app audio, the name sTools uses) for this permission.
    public var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen & System Audio Recording"
        case .appAudio: "App audio"
        case .microphone: "Microphone"
        case .camera: "Camera"
        }
    }

    /// The one-sentence reason shown to the user.
    public var reason: String {
        switch self {
        case .accessibility: "Accessibility allows for sTools to find the Minecraft window and follow it."
        case .screenRecording: "Lets sTools record Minecraft and the sources you add."
        case .appAudio: "Lets sTools record the sound of Minecraft and other apps."
        case .microphone: "Lets sTools record your voice."
        case .camera: "Lets sTools add your camera to recordings."
        }
    }

    /// Deep link to the System Settings pane that controls this permission.
    /// App audio shares the Screen & System Audio Recording pane on macOS 15 and later.
    public var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording, .appAudio: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .camera: pane = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// Whether macOS may only apply a grant after the app is relaunched.
    public var mayNeedRelaunch: Bool { self == .screenRecording }
}

/// What the system currently says about a permission.
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// The system offers no way to tell (app audio before the first request).
    case unknown
}
