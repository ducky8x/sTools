/// Where Timer Overlay is in a run (spec 5.6.1), as the controller tracks it. The press table (spec 5.6.2)
/// and the overlay both read it.
public enum TimerPhase: String, Sendable, CaseIterable {
    /// Nothing counts and no overlay is up.
    case idle
    /// A countdown runs and the overlay is up, unless a visibility setting hides it for now.
    case counting
    /// The countdown is frozen. The overlay shows it marked Paused, then hides as "While paused" says.
    case paused
    /// Zero has passed and the alarm rings; the overlay shows its time's-up look.
    case ringing
    /// The alarm has ended and the overlay stays a moment in its time's-up look before it leaves.
    case lingering
    /// The overlay is on its way out. A press now counts as a press while idle.
    case leaving
}
