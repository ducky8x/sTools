import AppKit
import Observation
import STDesign
import STPlatform
import SwiftUI

/// Owns the NBB Overlay tool's state: the six SSE subscriptions (via `NBBConnection`) and the one
/// overlay panel they drive (spec 5.1).
@MainActor
@Observable
public final class NBBOverlayController: ToolController {
    public private(set) var isEnabled = false
    public var settings: NBBOverlaySettings {
        didSet {
            guard settings != oldValue else { return }
            services.settings.save(settings)
            refreshIfEnabled()
        }
    }

    @ObservationIgnored private let services: ToolServices
    @ObservationIgnored private let connection: NBBConnection
    @ObservationIgnored private let panel = OverlayPanel(role: .topmost)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The panel's frame and the display it's shown on, from the last `refreshIfEnabled()` — what a
    /// live placement-mode drag or resize starts from.
    @ObservationIgnored private var dragStartFrame: CGRect?
    @ObservationIgnored private var resizeStartFrame: CGRect?
    @ObservationIgnored private var currentDisplay: DisplayInfo?
    /// How many times the overlay's content was built into the panel. For tests.
    @ObservationIgnored private(set) var drawCount = 0
    /// What the panel shows now, so a refresh that changes nothing it draws (Minecraft gaining or losing focus,
    /// a stream reconnecting with the same values) leaves the content alone instead of building it again.
    @ObservationIgnored private var drawn: DrawnOverlay?

    private struct DrawnOverlay: Equatable {
        var content: NBBOverlayContent
        var messages: [String]
        var settings: NBBOverlaySettings
    }

    public init(services: ToolServices, connection: NBBConnection = NBBConnection()) {
        self.services = services
        self.connection = connection
        settings = services.settings.load(NBBOverlaySettings.self)
    }

    /// A sample result for the Prologue's NBB Overlay trial (spec D5), shown only while Ninjabrain Bot sends
    /// nothing, and labeled as a sample on the overlay. Nil everywhere else.
    public var sample: NBBEvents.Stronghold? {
        didSet { if sample != oldValue { refreshIfEnabled() } }
    }

    /// Ninjabrain Bot's latest stronghold result, as it sent it.
    public var stronghold: NBBEvents.Stronghold? { connection.stronghold }

    /// The line under a sample result.
    public static let sampleNote = "Sample result: Ninjabrain Bot isn\u{2019}t connected."

    /// Ninjabrain Bot's reported version, for the page's requirement strip.
    public var nbbVersion: String? { connection.version }
    /// Whether the stronghold subscription is currently connected.
    public var isReachable: Bool { connection.isReachable }

    /// What the overlay shows for Ninjabrain Bot's live result, for the page's preview. Never the intro's sample,
    /// which is shown only in the intro's trial.
    var previewContent: NBBOverlayContent {
        NBBOverlayLayout.content(
            stronghold: connection.stronghold, blind: connection.blind, divine: connection.divine,
            boat: connection.boat, allAdvancements: connection.allAdvancements, maxPredictionRows: settings.maxPredictionRows)
    }

    /// Ninjabrain Bot's information messages as the overlay shows them, for the page's preview.
    var previewMessages: [(severity: NBBEvents.MessageSeverity, text: String)] {
        NBBOverlayLayout.plainTextMessages(from: connection.informationMessages?.informationMessages ?? [])
    }

    /// Resets every setting to its shipped default.
    public func resetToDefault() {
        settings = NBBOverlaySettings.defaultValue
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            connection.start()
            observeChanges()
            refreshIfEnabled()
        } else {
            connection.stop()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            panel.hide()
            // Off, the overlay's view tree goes too; switching on builds it again.
            panel.contentView = nil
            drawn = nil
        }
    }

    // MARK: - Placement mode (spec 5.1.5)

    /// `translation` is cumulative from where the drag started (SwiftUI `DragGesture` convention).
    /// Moves the real window immediately for a smooth drag; `placementMoveEnded()` commits the
    /// settled position back to `offsetX`/`offsetY` (snapped, if enabled).
    public func placementMoveChanged(_ translation: CGSize) {
        guard settings.placementModeEnabled else { return }
        let start = dragStartFrame ?? panel.frame
        dragStartFrame = start
        let moved = CGRect(
            origin: CGPoint(x: start.origin.x + translation.width, y: start.origin.y - translation.height),
            size: start.size)
        panel.moveTo(frame: moved)
    }

    public func placementMoveEnded() {
        defer { dragStartFrame = nil }
        guard settings.placementModeEnabled, let display = currentDisplay else { return }
        var frame = panel.frame
        if settings.snappingEnabled {
            frame = PlacementSnapping.snapped(frame, in: display.frame, threshold: 14)
        }
        panel.moveTo(frame: frame)
        settings.offsetX = Int((frame.midX - display.frame.midX).rounded())
        settings.offsetY = Int((display.frame.midY - frame.midY).rounded())
    }

    /// Same `translation` convention; keeps the panel's top-left corner fixed while the bottom-right
    /// handle drags, matching the handle's visual anchor.
    public func placementResizeChanged(_ translation: CGSize) {
        guard settings.placementModeEnabled else { return }
        let start = resizeStartFrame ?? panel.frame
        resizeStartFrame = start
        let minSize: CGFloat = 80
        let newWidth = max(CGFloat(NBBOverlaySettings.widthRange.lowerBound), start.width + translation.width)
        let newHeight = max(minSize, start.height + translation.height)
        let top = start.origin.y + start.height
        let resized = CGRect(x: start.origin.x, y: top - newHeight, width: newWidth, height: newHeight)
        panel.moveTo(frame: resized)
    }

    public func placementResizeEnded() {
        defer { resizeStartFrame = nil }
        guard settings.placementModeEnabled else { return }
        let frame = panel.frame
        settings.width = Int(frame.width.rounded())
        settings.aspectRatio = frame.height > 0 ? frame.width / frame.height : settings.aspectRatio
    }

    private func observeChanges() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfEnabled() }
        })
        watchForUpdates()
    }

    /// `NBBConnection` and `services.minecraft` are `@Observable`; this re-arms itself after every
    /// change so a new SSE event or a Minecraft display change redraws the panel.
    private func watchForUpdates() {
        withObservationTracking {
            _ = connection.stronghold
            _ = connection.blind
            _ = connection.divine
            _ = connection.boat
            _ = connection.informationMessages
            _ = connection.allAdvancements
            _ = services.minecraft.active
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshIfEnabled()
                self?.watchForUpdates()
            }
        }
    }

    private func refreshIfEnabled() {
        guard isEnabled else { return }
        guard let display = targetDisplay() else {
            currentDisplay = nil
            panel.hide()
            return
        }
        currentDisplay = display
        let showsSample = connection.stronghold == nil && sample != nil
        let content = NBBOverlayLayout.content(
            stronghold: connection.stronghold ?? sample, blind: connection.blind, divine: connection.divine,
            boat: connection.boat, allAdvancements: connection.allAdvancements, maxPredictionRows: settings.maxPredictionRows)
        var messages = NBBOverlayLayout.plainTextMessages(from: connection.informationMessages?.informationMessages ?? [])
        if showsSample { messages.append((severity: .info, text: Self.sampleNote)) }

        // Placement mode always shows the plate (so there's something to grab), regardless of data or
        // focus; otherwise both independent restrictions apply (spec: "an option for both").
        if !settings.placementModeEnabled {
            if settings.requiresMinecraftFocus, services.minecraft.active?.isFrontmost != true {
                panel.hide()
                return
            }
            if settings.requiresData, content == .hidden, messages.isEmpty {
                panel.hide()
                return
            }
        }

        // The panel is click-through by default (.topmost role); placement mode needs real mouse
        // events to receive the move/resize drags at all. This was the actual bug behind "I can't
        // click the overlay or the handle" — the SwiftUI-side `allowsHitTesting` toggle alone can't
        // override an AppKit window that's still set to ignore mouse events outright.
        panel.isMouseHandlingEnabled = settings.placementModeEnabled

        // The position only moves the panel, so it isn't part of what's drawn: a drag doesn't rebuild the content.
        var drawnSettings = settings
        drawnSettings.offsetX = 0
        drawnSettings.offsetY = 0
        let key = DrawnOverlay(content: content, messages: messages.map { "\($0.severity.rawValue)|\($0.text)" }, settings: drawnSettings)
        if drawn != key {
            panel.setContent(NBBOverlayView(
                content: content, messages: messages, settings: settings,
                onMoveChanged: { [weak self] in self?.placementMoveChanged($0) },
                onMoveEnded: { [weak self] in self?.placementMoveEnded() },
                onResizeChanged: { [weak self] in self?.placementResizeChanged($0) },
                onResizeEnded: { [weak self] in self?.placementResizeEnded() }))
            drawn = key
            drawCount += 1
        }

        let size = CGSize(width: CGFloat(settings.width), height: CGFloat(settings.width) / settings.aspectRatio)
        let origin = CGPoint(
            x: display.frame.midX + CGFloat(settings.offsetX) - size.width / 2,
            y: display.frame.midY - CGFloat(settings.offsetY) - size.height / 2)
        panel.show(frame: CGRect(origin: origin, size: size))
    }

    private func targetDisplay() -> DisplayInfo? {
        if let id = services.minecraft.active?.displayID, let display = services.displays.displays.first(where: { $0.id == id }) {
            return display
        }
        return services.displays.main
    }
}
