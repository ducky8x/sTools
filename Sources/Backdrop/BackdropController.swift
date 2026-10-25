import AppKit
import Observation
import STDesign
import STPlatform
import SwiftUI

/// A window the backdrop sits under while Minecraft isn't running.
public struct BackdropStandIn: Equatable, Sendable {
    public var windowNumber: Int
    public var displayID: UInt32

    public init(windowNumber: Int, displayID: UInt32) {
        self.windowNumber = windowNumber
        self.displayID = displayID
    }
}

/// Owns the Window Backdrop tool's state and its one overlay panel per covered display (spec 5.2).
@MainActor
@Observable
public final class BackdropController: ToolController {
    public private(set) var isEnabled = false
    public var settings: BackdropSettings {
        didSet {
            guard settings != oldValue else { return }
            services.settings.save(settings)
            reconcile()
        }
    }

    /// While Minecraft isn't running, the backdrop covers this window's display and sits right under it: the
    /// Prologue's Window Backdrop trial uses the sTools window (spec D6). Nil everywhere else.
    public var standIn: BackdropStandIn? {
        didSet { if standIn != oldValue { reconcile() } }
    }

    @ObservationIgnored private let services: ToolServices
    @ObservationIgnored private let imagesDirectory: URL
    @ObservationIgnored private let showsPanels: Bool
    @ObservationIgnored private var panels: [UInt32: OverlayPanel] = [:]
    /// Imported images by name, loaded when first drawn or previewed and let go when the tool switches off. A
    /// screen-sized image is tens of megabytes once decoded. A name that didn't load maps to nil.
    @ObservationIgnored private var images: [String: CGImage?] = [:]
    @ObservationIgnored private var imageImportErrorsByDisplay: [UInt32: String] = [:]
    @ObservationIgnored private var mainImageImportError: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// What each display's panel shows now, so re-ordering it (on every app switch while the tool is on) doesn't
    /// draw the same full-screen fill again.
    @ObservationIgnored private var drawnFills: [UInt32: DrawnFill] = [:]
    /// What each display's panel shows, kept for as long as the panel so a new fill can crossfade from the old one.
    @ObservationIgnored private var layers: [UInt32: BackdropLayers] = [:]
    /// For Reduce animations: while motion is reduced, a new fill replaces the old one at once.
    @ObservationIgnored private let theme: STTheme?
    /// How many times a fill was drawn into a panel. For tests.
    @ObservationIgnored private(set) var drawCount = 0

    private struct DrawnFill: Equatable {
        var fill: BackdropSettings.Fill
        var opacityPercent: Int
        var hasImage: Bool
    }

    /// `imagesDirectory` defaults to `~/Library/Application Support/sTools/Images`; pass a temp
    /// directory in tests.
    public convenience init(
        services: ToolServices,
        imagesDirectory: URL = SettingsStore.defaultDirectory().appending(path: "Images", directoryHint: .isDirectory),
        theme: STTheme? = nil
    ) {
        self.init(services: services, imagesDirectory: imagesDirectory, showsPanels: true, theme: theme)
    }

    /// Tests pass `showsPanels: false`: panels still get their content and frame, but are never ordered onto a
    /// screen.
    init(services: ToolServices, imagesDirectory: URL, showsPanels: Bool, theme: STTheme? = nil) {
        self.services = services
        self.theme = theme
        self.imagesDirectory = imagesDirectory
        self.showsPanels = showsPanels
        settings = services.settings.load(BackdropSettings.self)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            observeChanges()
            reconcile()
        } else {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            releasePanels()
        }
    }

    /// The panels (with their full-screen layers) and the images they drew, while the tool is on. For tests.
    var panelCount: Int { panels.count }
    var loadedImageCount: Int { images.count }

    /// The import error for the main (Minecraft display) fill's image, for the settings view.
    public var imageImportError: String? { mainImageImportError }

    /// Imports an image for the main fill (Minecraft's display).
    public func importImage(from url: URL) {
        switch BackdropImageImport.importImage(from: url, into: imagesDirectory) {
        case .success(let relativeName):
            settings.fill.imageName = relativeName
            settings.fill.kind = .image
            mainImageImportError = nil
            loadImageIfNeeded(relativeName)
        case .failure(let error):
            mainImageImportError = error.message
        }
    }

    /// The import error for `displayID`'s override fill's image, for the settings view.
    public func imageImportError(for displayID: UInt32) -> String? { imageImportErrorsByDisplay[displayID] }

    /// Imports an image for `displayID`'s override fill, creating the override if needed.
    public func importImage(from url: URL, forDisplayID displayID: UInt32) {
        switch BackdropImageImport.importImage(from: url, into: imagesDirectory) {
        case .success(let relativeName):
            var fill = settings.fill(for: displayID)
            fill.imageName = relativeName
            fill.kind = .image
            setDisplayFill(fill, for: displayID)
            imageImportErrorsByDisplay[displayID] = nil
            loadImageIfNeeded(relativeName)
        case .failure(let error):
            imageImportErrorsByDisplay[displayID] = error.message
        }
    }

    /// Replaces (or adds) `displayID`'s override fill.
    public func setDisplayFill(_ fill: BackdropSettings.Fill, for displayID: UInt32) {
        if let index = settings.displayFills.firstIndex(where: { $0.displayID == displayID }) {
            settings.displayFills[index].fill = fill
        } else {
            settings.displayFills.append(BackdropSettings.DisplayFill(displayID: displayID, fill: fill))
        }
    }

    /// Adds or removes `displayID` from the covered-displays list.
    public func setCovered(_ covered: Bool, displayID: UInt32) {
        if covered {
            guard !settings.additionalDisplayIDs.contains(displayID) else { return }
            settings.additionalDisplayIDs.append(displayID)
        } else {
            settings.additionalDisplayIDs.removeAll { $0 == displayID }
            settings.displayFills.removeAll { $0.displayID == displayID }
        }
    }

    public func isCovered(displayID: UInt32) -> Bool { settings.additionalDisplayIDs.contains(displayID) }

    /// Resets every setting to its shipped default.
    public func resetToDefault() {
        settings = BackdropSettings.defaultValue
    }

    /// The connected displays, for the settings view's "Other displays" list.
    public var availableDisplays: [DisplayInfo] { services.displays.displays }

    /// The display Minecraft's followed instance mostly sits on, if any — excluded from "Other
    /// displays" since it's covered automatically whenever the tool is on.
    public var minecraftDisplayID: UInt32? { services.minecraft.active?.displayID }

    /// Image for a fill's `imageName`, loading and caching it on first use.
    func image(for fill: BackdropSettings.Fill) -> CGImage? {
        guard let name = fill.imageName else { return nil }
        loadImageIfNeeded(name)
        return images[name] ?? nil
    }

    // MARK: - Placement

    private func observeChanges() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        watchMinecraft()
    }

    /// Minecraft's focused window, its display, and the connected display list are all `@Observable`;
    /// Observation only re-runs SwiftUI view bodies on its own, so this re-arms itself after every
    /// change to also call `reconcile()` (spec 5.2.2's "focused window changing", "moving displays",
    /// "display changes" triggers).
    private func watchMinecraft() {
        withObservationTracking {
            _ = services.minecraft.active
            _ = services.displays.displays
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconcile()
                self?.watchMinecraft()
            }
        }
    }

    /// Re-reads Minecraft and display state and brings every panel in line. Safe to call as often as
    /// needed; a panel already showing the right content at the right place is left alone by AppKit.
    func reconcile() {
        guard isEnabled else { return }
        if services.minecraft.active == nil, let standIn,
           let display = services.displays.displays.first(where: { $0.id == standIn.displayID }) {
            let panel = panel(for: display.id)
            draw(settings.fill(for: display.id), in: panel, displayID: display.id)
            show(panel, frame: display.frame, below: standIn.windowNumber)
            for (displayID, other) in panels where displayID != display.id { other.hide() }
            return
        }
        let covered = coveredDisplayIDs()
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: covered.sorted(),
            minecraft: services.minecraft.active?.window,
            minecraftDisplayID: services.minecraft.active?.displayID,
            isMinecraftFocused: services.minecraft.active?.isFrontmost == true,
            hideOnFullScreenScope: settings.hideOnFullScreenScope,
            hidesWhenMinecraftNotFocused: settings.hidesWhenMinecraftNotFocused)

        for plan in plans {
            guard let display = services.displays.displays.first(where: { $0.id == plan.displayID }),
                  plan.isVisible, let belowWindowNumber = plan.orderBelowWindowNumber else {
                panels[plan.displayID]?.hide()
                continue
            }
            let panel = panel(for: plan.displayID)
            draw(settings.fill(for: plan.displayID), in: panel, displayID: plan.displayID)
            show(panel, frame: display.frame, below: Int(belowWindowNumber))
        }
        for (displayID, panel) in panels where !covered.contains(displayID) {
            panel.hide()
        }
    }

    private func show(_ panel: OverlayPanel, frame: CGRect, below windowNumber: Int) {
        if showsPanels {
            panel.showBelow(frame: frame, windowNumber: windowNumber)
        } else {
            panel.moveTo(frame: frame)
        }
    }

    /// Gives `panel` the fill, unless it already shows exactly that. A new fill crossfades from the old one over
    /// *Fill transition* (spec 5.2.4); the opacity changes at once.
    private func draw(_ fill: BackdropSettings.Fill, in panel: OverlayPanel, displayID: UInt32) {
        let image = image(for: fill)
        let drawn = DrawnFill(fill: fill, opacityPercent: settings.opacityPercent, hasImage: image != nil)
        guard drawnFills[displayID] != drawn else { return }
        let opacity = Double(settings.opacityPercent) / 100
        if let layers = layers[displayID] {
            let previous = drawnFills[displayID]
            layers.opacity = opacity
            if previous?.fill != fill || previous?.hasImage != (image != nil) {
                let seconds = fillTransitionSeconds
                STMotion.animate(.easeInOut(duration: seconds), reduce: seconds == 0) {
                    layers.show(fill, image: image)
                }
            }
        } else {
            let layers = BackdropLayers(fill: fill, image: image, opacity: opacity)
            self.layers[displayID] = layers
            panel.setContent(BackdropCrossfadeView(layers: layers))
        }
        drawnFills[displayID] = drawn
        drawCount += 1
    }

    /// How long a fill change crossfades: none while motion is reduced.
    var fillTransitionSeconds: Double {
        theme?.reduceMotion == true ? 0 : settings.fillTransitionSeconds
    }

    /// The fill a display's panel shows now, for tests.
    func shownFill(on displayID: UInt32) -> BackdropSettings.Fill? { layers[displayID]?.current.fill }

    /// Minecraft's own display (while it's running) plus every additional display the user checked,
    /// limited to displays that actually exist right now.
    private func coveredDisplayIDs() -> Set<UInt32> {
        var ids = Set(settings.additionalDisplayIDs)
        if let minecraftDisplay = services.minecraft.active?.displayID { ids.insert(minecraftDisplay) }
        let connected = Set(services.displays.displays.map(\.id))
        return ids.intersection(connected)
    }

    private func panel(for displayID: UInt32) -> OverlayPanel {
        if let existing = panels[displayID] { return existing }
        let panel = OverlayPanel(role: .backdrop)
        panels[displayID] = panel
        return panel
    }

    /// Switching off closes the panels instead of only hiding them: a hidden panel would keep its full-screen layer
    /// and image in memory for nothing. Switching on again builds them anew.
    private func releasePanels() {
        for panel in panels.values {
            panel.hide()
            panel.close()
        }
        panels.removeAll()
        drawnFills.removeAll()
        layers.removeAll()
        images.removeAll()
    }

    private func loadImageIfNeeded(_ name: String?) {
        guard let name, images[name] == nil else { return }
        let url = imagesDirectory.appending(path: (name as NSString).lastPathComponent)
        images[name] = BackdropImageImport.loadImage(at: url)
    }
}

/// What one backdrop panel shows. A new fill gets a new id, so SwiftUI crossfades from the old layer to it.
@MainActor
@Observable
final class BackdropLayers {
    struct Layer {
        var id: Int
        var fill: BackdropSettings.Fill
        var image: CGImage?
    }

    private(set) var current: Layer
    var opacity: Double

    init(fill: BackdropSettings.Fill, image: CGImage?, opacity: Double) {
        current = Layer(id: 0, fill: fill, image: image)
        self.opacity = opacity
    }

    func show(_ fill: BackdropSettings.Fill, image: CGImage?) {
        current = Layer(id: current.id + 1, fill: fill, image: image)
    }
}

/// The backdrop panel's content: the current fill, crossfading from the last one when it changes.
struct BackdropCrossfadeView: View {
    let layers: BackdropLayers

    var body: some View {
        ZStack {
            BackdropFillView(fill: layers.current.fill, image: layers.current.image)
                .id(layers.current.id)
                .transition(.opacity)
        }
        .opacity(layers.opacity)
    }
}
