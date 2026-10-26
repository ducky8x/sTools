import Foundation

/// What the Start-timer key does, in one short line for the Timer page's Hotkey row (spec 5.6.2): it starts the timer,
/// and the cancel gesture chosen in Advanced switches Timer Overlay off. The rest of the row is every tool page's
/// (spec 6.1). Wording from ducky's M9 review.
public enum TimerKeyLine {
    public static func text(for gesture: TimerOverlaySettings.CancelGesture) -> String {
        switch gesture {
        case .doublePress: "Starts the timer. A double press switches Timer Overlay off."
        case .hold: "Starts the timer. Hold it for \(seconds(PressPolicy.holdDuration)) s to switch Timer Overlay off."
        case .off: "Starts the timer."
        }
    }

    private static func seconds(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
