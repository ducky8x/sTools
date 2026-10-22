import Observation
import TimerOverlay

/// Timer Overlay on the Dock icon (spec 5.6.7, Advanced "Countdown on the Dock icon", off by default): a badge with
/// the time left, and Start / Pause / Cancel in the Dock menu.
extension AppModel {
    /// One item of the Dock menu's timer part.
    struct TimerDockItem: Equatable {
        enum Action: Equatable { case start, pause, resume, cancel }
        var title: String
        var action: Action
    }

    /// The badge: the time left while a countdown runs or is paused, "0:00" once time's up, nil otherwise or while
    /// the setting is off. It reads only `status`, which changes at most once a second.
    var timerDockBadge: String? {
        guard let timer = timerOverlay, timer.settings.showsDockCountdown, isOn(.timerOverlay) else { return nil }
        return timer.status.badgeText
    }

    /// The Dock menu's timer items while the setting is on: Start, then Pause or Resume and Cancel while a run is
    /// live. Empty while the setting is off or the tool can't switch on.
    var timerDockItems: [TimerDockItem] {
        guard let timer = timerOverlay, timer.settings.showsDockCountdown,
              isOn(.timerOverlay) || canSwitch(.timerOverlay) else { return [] }
        var items = [TimerDockItem(title: "Start Timer", action: .start)]
        switch timer.phase {
        case .counting: items.append(TimerDockItem(title: "Pause Timer", action: .pause))
        case .paused: items.append(TimerDockItem(title: "Resume Timer", action: .resume))
        case .idle, .ringing, .lingering, .leaving: break
        }
        if timer.phase != .idle && timer.phase != .leaving {
            items.append(TimerDockItem(title: "Cancel Timer", action: .cancel))
        }
        return items
    }

    /// Carries out a Dock menu item. Start switches the tool on first, as the page's Start does (plan decision 7).
    func performTimerDockItem(_ action: TimerDockItem.Action) {
        guard let timer = timerOverlay else { return }
        switch action {
        case .start: timer.start()
        case .pause: timer.pause()
        case .resume: timer.resume()
        case .cancel: timer.cancel()
        }
    }

    /// Calls `apply` with the badge now and again each time it changes, for as long as the model lives.
    func watchTimerDockBadge(_ apply: @escaping @MainActor (String?) -> Void) {
        let badge = withObservationTracking {
            timerDockBadge
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchTimerDockBadge(apply) }
        }
        apply(badge)
    }
}
