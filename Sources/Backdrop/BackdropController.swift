import AppKit
import Observation
import STPlatform

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

    @ObservationIgnored private let services: ToolServices
    @ObservationIgnored private let imagesDirectory: URL
    @ObservationIgnored private var panels: [UInt32: OverlayPanel] = [:]
    @ObservationIgnored private var images: [String: CGImage] = [:]
    @ObservationIgnored private var imageImportErrorsByDisplay: [UInt32: String] = [:]
    @ObservationIgnored private var mainImageImportError: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `imagesDirectory` defaults to `~/Library/Application Support/sTools/Images`; pass a temp
    /// directory in tests.
    public init(services: ToolServices, imagesDirectory: URL = SettingsStore.defaultDirectory().appending(path: "Images", directoryHint: .isDirectory)) {
        self.services = services
        self.imagesDirectory = imagesDirectory
        settings = services.settings.load(BackdropSettings.self)
        loadImagesIfNeeded()
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
            hideAll()
        }
    }

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
        return images[name]
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
            let fill = settings.fill(for: plan.displayID)
            panel.setContent(BackdropFillView(fill: fill, image: image(for: fill), opacity: Double(settings.opacityPercent) / 100))
            panel.showBelow(frame: display.frame, windowNumber: Int(belowWindowNumber))
        }
        for (displayID, panel) in panels where !covered.contains(displayID) {
            panel.hide()
        }
    }

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

    private func hideAll() {
        for panel in panels.values { panel.hide() }
    }

    private func loadImagesIfNeeded() {
        loadImageIfNeeded(settings.fill.imageName)
        for displayFill in settings.displayFills { loadImageIfNeeded(displayFill.fill.imageName) }
    }

    private func loadImageIfNeeded(_ name: String?) {
        guard let name, images[name] == nil else { return }
        let url = imagesDirectory.appending(path: (name as NSString).lastPathComponent)
        images[name] = BackdropImageImport.loadImage(at: url)
    }
}
