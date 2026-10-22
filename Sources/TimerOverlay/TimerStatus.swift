/// Timer Overlay's state in a few words, for the sidebar, Home and the Dock badge (spec 5.6.3): *Off* ·
/// *Ready* · *2:14 left* · *Paused, 1:02* · *Time's up*.
///
/// It counts whole seconds, rounded up as the overlay rounds them, so it changes at most once a second even while
/// the overlay shows tenths. Everything that reads it (the sidebar, Home, the Dock badge) redraws at most that often.
/// The words are placeholder wording for M9.
public enum TimerStatus: Equatable, Sendable {
    /// The tool is off.
    case off
    /// On, with nothing counting.
    case ready
    /// A countdown runs, with this many whole seconds left (rounded up).
    case counting(secondsLeft: Int)
    /// The countdown is paused with this many whole seconds left.
    case paused(secondsLeft: Int)
    /// Zero has passed: the alarm rings, or the overlay lingers after it.
    case timesUp

    /// What the sidebar and Home show, in small caps: "Off", "Ready", "2:14 left", "Paused, 1:02", "Time's up".
    public var text: String {
        switch self {
        case .off: "Off"
        case .ready: "Ready"
        case .counting(let seconds): "\(Self.time(seconds)) left"
        case .paused(let seconds): "Paused, \(Self.time(seconds))"
        case .timesUp: "Time\u{2019}s up"
        }
    }

    /// The Dock badge while "Countdown on the Dock icon" is on: the time left ("2:14"), the frozen time while paused,
    /// "0:00" once time's up, and no badge while nothing counts.
    public var badgeText: String? {
        switch self {
        case .off, .ready: nil
        case .counting(let seconds), .paused(let seconds): Self.time(seconds)
        case .timesUp: Self.time(0)
        }
    }

    /// `M:SS`, or `H:MM:SS` from an hour: "2:14", "0:05", "1:02:03".
    private static func time(_ seconds: Int) -> String {
        ClockFormat.string(seconds: seconds, format: .shortMinutes)
    }
}
