import Foundation

/// What the overlay shows at one moment (plan, "Interfaces between tasks"). The controller builds one for each shown
/// change and hands it to the presenter; the page's preview plate draws the same value.
public struct TimerOverlayContent: Equatable, Sendable {
    /// Which colors the time is drawn in (spec 5.6.4). The words and digits always say the same thing, so color is
    /// never the only signal (spec 3.3).
    public enum State: String, Sendable, CaseIterable {
        case counting
        /// `gold` digits from "Color near zero"'s first time.
        case nearZeroGold
        /// `danger` digits from its second time.
        case nearZeroDanger
        /// Dimmed digits, marked *Paused*.
        case paused
        /// The time's-up look, from zero until the overlay leaves.
        case timesUp
    }

    /// The time as written: `02:30`, `00:09.9`, the word at zero, or overtime such as `+0:07`.
    public var text: String
    public var state: State
    /// The time left as a fraction of the run, 1 → 0, stepped with the shown seconds; nil draws no bar or ring.
    public var progress: Double? {
        didSet { progress = Self.sanitized(progress) }
    }
    /// The small-caps label, or nil for none.
    public var label: String?
    /// Whether the plate's edge turns `danger`, while it's dragged over an area the speedrun rules need visible
    /// (spec 5.6.5).
    public var showsDangerEdge: Bool

    public init(text: String, state: State = .counting, progress: Double? = nil, label: String? = nil,
                showsDangerEdge: Bool = false) {
        self.text = text
        self.state = state
        self.progress = Self.sanitized(progress)
        self.label = label
        self.showsDangerEdge = showsDangerEdge
    }

    /// The content `settings` ask for: their label when it's on, and `steppedProgress` (as from
    /// `Countdown.steppedProgress`) when they show a bar or a ring.
    public init(text: String, state: State, steppedProgress: Double, settings: TimerOverlaySettings,
                showsDangerEdge: Bool = false) {
        let label = settings.labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(text: text, state: state, progress: settings.progress == .off ? nil : steppedProgress,
                  label: settings.showsLabel && !label.isEmpty ? label : nil, showsDangerEdge: showsDangerEdge)
    }

    /// The state while counting with `shownSeconds` on the overlay: `gold`, then `danger`, from the times "Color near
    /// zero" sets (spec 5.6.4, Timer round C3), and plain counting otherwise.
    public static func countingState(shownSeconds: Int, settings: TimerOverlaySettings) -> State {
        switch settings.nearZero {
        case .off:
            return .counting
        case .gold:
            return shownSeconds <= settings.nearZeroGoldSeconds ? .nearZeroGold : .counting
        case .goldThenDanger:
            if shownSeconds <= settings.nearZeroDangerSeconds { return .nearZeroDanger }
            return shownSeconds <= settings.nearZeroGoldSeconds ? .nearZeroGold : .counting
        }
    }

    private static func sanitized(_ progress: Double?) -> Double? {
        progress.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
    }
}
