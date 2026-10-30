import AppKit
import Observation

/// The connected displays, kept current as the configuration changes.
@MainActor
@Observable
public final class DisplayDirectory {
    public private(set) var displays: [DisplayInfo]

    public var main: DisplayInfo? { displays.first(where: \.isMain) }

    @ObservationIgnored private let screenProvider: @MainActor () -> [DisplayInfo]
    @ObservationIgnored private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    public convenience init() {
        self.init(screenProvider: { NSScreen.screens.compactMap { DisplayInfo(screen: $0) } })
    }

    /// Separate from `init()` so tests and benchmarks can drive the directory with synthetic layouts, such as displays outside
    /// every real screen.
    public init(screenProvider: @escaping @MainActor () -> [DisplayInfo]) {
        self.screenProvider = screenProvider
        self.displays = screenProvider()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reloads the display list. Called automatically on screen configuration changes.
    public func refresh() {
        let updated = screenProvider()
        if updated != displays { displays = updated }
    }
}
