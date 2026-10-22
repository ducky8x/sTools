import Foundation

/// sTools' own alarm sounds for Timer Overlay (spec 5.6.6): warm, alarm-length sounds (1–2 s) in the family of
/// the UI sounds, made by `scripts/generate-sounds.swift` into `Resources/Sounds/Alarms`.
///
/// Unlike `STSound`, nothing here plays or loads anything, and nothing loads these ahead of time: Timer Overlay
/// reads one only when its alarm, or a preview, plays it.
public enum STAlarmSound: String, CaseIterable, Sendable {
    /// A mellow mallet arpeggio rising to the octave.
    case ember
    /// A bright bell, an open fifth, struck twice.
    case lantern
    /// One deep tower bell, left to ring.
    case toll
    /// A wooden knock-knock, twice.
    case knock

    /// The name the alarm picker shows. Placeholder wording for M9.
    public var title: String {
        switch self {
        case .ember: "Ember"
        case .lantern: "Lantern"
        case .toll: "Toll"
        case .knock: "Knock"
        }
    }

    /// The bundled `Resources/Sounds/Alarms/<rawValue>.wav`. Asking loads nothing.
    public var resourceURL: URL? {
        STResources.bundle.url(forResource: rawValue, withExtension: "wav", subdirectory: "Resources/Sounds/Alarms")
    }
}
