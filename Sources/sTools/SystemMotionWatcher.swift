import AppKit
import STDesign

/// Keeps the theme's copy of macOS's Reduce motion (Accessibility ▸ Display) current from launch on, with or without
/// the main window: the hotkey confirmation reads it too. Tests pass their own reading and notification center, so
/// the real Mac's setting is never read.
@MainActor
final class SystemMotionWatcher {
    private let theme: STTheme
    private let center: NotificationCenter
    private let readsReduceMotion: @MainActor () -> Bool
    private var observer: NSObjectProtocol?

    init(theme: STTheme,
         center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         readsReduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.theme = theme
        self.center = center
        self.readsReduceMotion = readsReduceMotion
        refresh()
        observer = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Reads the setting again; the theme only changes when it did.
    func refresh() {
        let reduces = readsReduceMotion()
        if theme.systemReduceMotion != reduces { theme.systemReduceMotion = reduces }
    }
}
