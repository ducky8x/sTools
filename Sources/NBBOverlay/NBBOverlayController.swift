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
    /// The running Ninjabrain Bots, watched while the tool is on: which one the overlay reads, and the page's list.
    public let copies: NBBCopiesMonitor
    /// What the followed copy's window shows, while it's read from its window (it doesn't hold the API).
    public private(set) var windowSnapshot: NBBWindowSnapshot?
    /// Whether a read of a followed copy's window came back since window reading started. Until then the overlay goes
    /// on showing what it showed (the API's result, or the copy it followed before), so a switch doesn't blink.
    private(set) var hasReadWindow = false
    @ObservationIgnored private let windowReader: any NBBWindowReading
    @ObservationIgnored private var windowPoll: Task<Void, Never>?
    @ObservationIgnored private var windowPollPID: Int32?
    /// Counts window polls, so a read that ends after its poll stopped or moved to another copy is dropped.
    @ObservationIgnored private var windowPollGeneration = 0
    /// How often a copy's window is read: twice a second, off the main actor (about 20 ms each, nearly all of it
    /// waiting for Ninjabrain Bot's answers).
    @ObservationIgnored private let windowPollInterval: Duration
    @ObservationIgnored private let panel = OverlayPanel(role: .topmost)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// For Reduce animations: while motion is reduced, the overlay shows and hides at once.
    @ObservationIgnored private let theme: STTheme?
    /// Counts fades, so a fade-out's end hides the panel only if nothing showed it again since.
    @ObservationIgnored private var fadeGeneration = 0
    @ObservationIgnored private var isFadingOut = false
    /// Whether the panel is down because Ninjabrain Bot had nothing to show (a reset), so new data fades it back in.
    @ObservationIgnored private var hiddenForNoData = true

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
        var boat: NBBEvents.Boat?
        var settings: NBBOverlaySettings
    }

    public init(
        services: ToolServices, connection: NBBConnection = NBBConnection(), copies: NBBCopiesMonitor? = nil, theme: STTheme? = nil,
        windowReader: (any NBBWindowReading)? = nil, windowPollInterval: Duration = .milliseconds(500)
    ) {
        self.services = services
        self.theme = theme
        self.windowReader = windowReader ?? AXNBBWindowReader()
        self.windowPollInterval = windowPollInterval
        self.connection = connection
        self.copies = copies ?? NBBCopiesMonitor()
        settings = services.settings.load(NBBOverlaySettings.self)
    }

    /// A sample result for the Prologue's NBB Overlay trial (spec D5), shown only while Ninjabrain Bot sends
    /// nothing, and labeled as a sample on the overlay. Nil everywhere else.
    public var sample: NBBEvents.Stronghold? {
        didSet { if sample != oldValue { refreshIfEnabled() } }
    }

    /// Ninjabrain Bot's latest stronghold result: from the API, or from the followed copy's window.
    public var stronghold: NBBEvents.Stronghold? { readsWindow ? windowSnapshot?.stronghold : connection.stronghold }

    /// Whether the overlay follows a copy it reads from its window (once the first read came back).
    public var readsWindow: Bool { copies.readsWindow && hasReadWindow }

    // The window gives predictions, eye throws and notes only; the boat and the other views come over the API.
    private var currentBlind: NBBEvents.Blind? { readsWindow ? nil : connection.blind }
    private var currentDivine: NBBEvents.Divine? { readsWindow ? nil : connection.divine }
    private var currentBoat: NBBEvents.Boat? { readsWindow ? nil : connection.boat }
    private var currentAllAdvancements: NBBEvents.AllAdvancements? { readsWindow ? nil : connection.allAdvancements }
    private var currentMessages: [(severity: NBBEvents.MessageSeverity, text: String)] {
        if readsWindow { return (windowSnapshot?.messages ?? []).map { (severity: .info, text: $0) } }
        return NBBOverlayLayout.plainTextMessages(from: connection.informationMessages?.informationMessages ?? [])
    }

    /// The line under a sample result.
    public static let sampleNote = "Sample result: Ninjabrain Bot isn\u{2019}t connected."

    /// Ninjabrain Bot's reported version, for the page's requirement strip.
    public var nbbVersion: String? { connection.version }
    /// Whether sTools can read the copy it follows: its window, or the API's stronghold subscription.
    public var isReachable: Bool { readsWindow ? windowSnapshot != nil : connection.isReachable }

    /// What the overlay shows for Ninjabrain Bot's live result, for the page's preview. Never the intro's sample,
    /// which is shown only in the intro's trial.
    var previewContent: NBBOverlayContent {
        NBBOverlayLayout.content(
            stronghold: stronghold, blind: currentBlind, divine: currentDivine,
            boat: currentBoat, allAdvancements: currentAllAdvancements, maxPredictionRows: settings.maxPredictionRows,
            locationDisplay: settings.locationDisplay, netherCoordinatesInNether: settings.showsNetherCoordinatesInNether)
    }

    /// Ninjabrain Bot's latest boat state, for the page's preview.
    var previewBoat: NBBEvents.Boat? { currentBoat }

    /// Ninjabrain Bot's information messages as the overlay shows them, for the page's preview.
    var previewMessages: [(severity: NBBEvents.MessageSeverity, text: String)] { currentMessages }

    /// Resets every setting to its shipped default.
    public func resetToDefault() {
        settings = NBBOverlaySettings.defaultValue
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            connection.start()
            copies.start()
            syncWindowReading()
            observeChanges()
            refreshIfEnabled()
        } else {
            connection.stop()
            copies.stop()
            syncWindowReading()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            fadeGeneration += 1
            isFadingOut = false
            hiddenForNoData = true
            panel.hide()
            panel.alphaValue = 1
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
            _ = copies.copies
            _ = copies.choice
            _ = windowSnapshot
            _ = hasReadWindow
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncWindowReading()
                self?.refreshIfEnabled()
                self?.watchForUpdates()
            }
        }
    }

    /// Reads the followed copy's window twice a second while the tool is on and that copy doesn't hold the API; stops
    /// otherwise. The reads run off the main actor, and a snapshot reaches it only when it differs from the last one.
    private func syncWindowReading() {
        let pid = isEnabled && copies.readsWindow ? copies.readCopy?.pid : nil
        guard pid != windowPollPID else { return }
        windowPoll?.cancel()
        windowPoll = nil
        windowPollPID = pid
        windowPollGeneration += 1
        guard let pid else {
            if windowSnapshot != nil { windowSnapshot = nil }
            if hasReadWindow { hasReadWindow = false }
            return
        }
        let generation = windowPollGeneration
        let reader = windowReader, interval = windowPollInterval
        windowPoll = Task.detached(priority: .utility) { [weak self] in
            var last: NBBWindowSnapshot??
            while !Task.isCancelled {
                let snapshot = await reader.read(pid: pid)
                if last != .some(snapshot) {
                    last = .some(snapshot)
                    await self?.showWindow(snapshot, generation: generation)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func showWindow(_ snapshot: NBBWindowSnapshot?, generation: Int) {
        guard generation == windowPollGeneration else { return }
        if snapshot != windowSnapshot { windowSnapshot = snapshot }
        if !hasReadWindow { hasReadWindow = true }
    }

    private func refreshIfEnabled() {
        guard isEnabled else { return }
        guard let display = targetDisplay() else {
            currentDisplay = nil
            hidePanel(fading: false)
            return
        }
        currentDisplay = display
        let showsSample = stronghold == nil && sample != nil
        let content = NBBOverlayLayout.content(
            stronghold: stronghold ?? sample, blind: currentBlind, divine: currentDivine,
            boat: currentBoat, allAdvancements: currentAllAdvancements, maxPredictionRows: settings.maxPredictionRows,
            locationDisplay: settings.locationDisplay, netherCoordinatesInNether: settings.showsNetherCoordinatesInNether)
        var messages = currentMessages
        if showsSample { messages.append((severity: .info, text: Self.sampleNote)) }

        // Placement mode always shows the plate (so there's something to grab), regardless of data or
        // focus; otherwise both independent restrictions apply (spec: "an option for both").
        if !settings.placementModeEnabled {
            if settings.requiresMinecraftFocus, services.minecraft.active?.isFrontmost != true {
                hidePanel(fading: false)
                return
            }
            if settings.requiresData, content == .hidden, messages.isEmpty,
               !NBBOverlayLayout.boatCountsAsData(currentBoat, settings: settings) {
                hidePanel(fading: true)
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
        let key = DrawnOverlay(
            content: content, messages: messages.map { "\($0.severity.rawValue)|\($0.text)" }, boat: currentBoat, settings: drawnSettings)
        if drawn != key {
            panel.setContent(NBBOverlayView(
                content: content, messages: messages, settings: settings, boat: currentBoat,
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
        showPanel(frame: CGRect(origin: origin, size: size))
    }

    // MARK: - Fade on reset (spec 5.1.1)

    /// How long a reset's fade takes: none while it's off, while motion is reduced, or at 0 s.
    var fadeDuration: TimeInterval {
        guard settings.fadeOnResetEnabled, theme?.reduceMotion != true else { return 0 }
        return settings.fadeSeconds
    }

    /// Whether the overlay is on screen (fading out counts as on screen), for tests.
    var isOverlayVisible: Bool { panel.isVisible }

    /// Hides the panel. `fading` is for Ninjabrain Bot running out of data (a reset): the panel fades out over
    /// `fadeDuration`, and new data before the fade ends brings it straight back. Anything else (Minecraft losing
    /// focus, no display) hides it at once.
    private func hidePanel(fading: Bool) {
        guard panel.isVisible, !isFadingOut || !fading else {
            if !panel.isVisible { hiddenForNoData = fading }
            return
        }
        fadeGeneration += 1
        let generation = fadeGeneration
        hiddenForNoData = fading
        let duration = fading ? fadeDuration : 0
        guard duration > 0 else {
            isFadingOut = false
            panel.hide()
            panel.alphaValue = 1
            return
        }
        isFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        // The panel goes once the fade is over, unless something showed it again meanwhile. A timed task rather than
        // the animation's completion handler, which AppKit doesn't call for a window it never draws.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.fadeGeneration == generation else { return }
            self.isFadingOut = false
            self.panel.hide()
            self.panel.alphaValue = 1
        }
    }

    /// Shows the panel at `frame`; after a reset it fades back in.
    private func showPanel(frame: CGRect) {
        let comingBack = !panel.isVisible || isFadingOut
        guard comingBack else {
            panel.show(frame: frame)
            return
        }
        fadeGeneration += 1
        let duration = hiddenForNoData ? fadeDuration : 0
        let wasFadingOut = isFadingOut
        isFadingOut = false
        hiddenForNoData = false
        guard duration > 0 else {
            panel.alphaValue = 1
            panel.show(frame: frame)
            return
        }
        if !wasFadingOut { panel.alphaValue = 0 }
        panel.show(frame: frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 1
        }
    }

    private func targetDisplay() -> DisplayInfo? {
        if let id = services.minecraft.active?.displayID, let display = services.displays.displays.first(where: { $0.id == id }) {
            return display
        }
        return services.displays.main
    }
}
