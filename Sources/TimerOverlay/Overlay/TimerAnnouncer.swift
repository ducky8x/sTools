import AppKit

/// What VoiceOver hears from Timer Overlay (spec 5.6.4). Placeholder wording for M9.
public enum TimerAnnouncement: Equatable, Sendable {
    /// "Timer started, 2 minutes 30 seconds".
    case started(seconds: Int)
    /// "Time's up".
    case timesUp

    public var text: String {
        switch self {
        case .started(let seconds): "Timer started, " + Self.words(seconds)
        case .timesUp: "Time\u{2019}s up"
        }
    }

    /// `seconds` as spoken: "2 minutes 30 seconds", "1 hour", leaving out the parts that are zero.
    private static func words(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let parts = [(total / 3600, "hour"), (total % 3600 / 60, "minute"), (total % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }
}

/// Speaks Timer Overlay's moments to VoiceOver. A protocol, so tests never post a real announcement.
@MainActor
public protocol TimerAnnouncing: AnyObject {
    func announce(_ announcement: TimerAnnouncement)
}

/// The live announcer: an accessibility announcement request, which VoiceOver speaks when it runs and which
/// costs nothing when it doesn't.
@MainActor
public final class TimerAnnouncer: TimerAnnouncing {
    private let post: @MainActor (String) -> Void

    public convenience init() {
        self.init(post: { text in
            NSAccessibility.post(
                element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        })
    }

    /// Tests pass their own `post`.
    init(post: @escaping @MainActor (String) -> Void) {
        self.post = post
    }

    public func announce(_ announcement: TimerAnnouncement) {
        post(announcement.text)
    }
}
