import AppKit
import Observation
import STDesign
import STPlatform

/// Owns the Crosshair tool's state and its one on-screen overlay.
@MainActor
@Observable
public final class CrosshairController: ToolController {
    public private(set) var isEnabled = false
    public var settings: CrosshairSettings {
        didSet {
            guard settings != oldValue else { return }
            services.settings.save(settings)
            refreshIfEnabled()
        }
    }

    @ObservationIgnored private let services: ToolServices
    @ObservationIgnored private let imagesDirectory: URL
    @ObservationIgnored private let panel = OverlayPanel(role: .topmost)
    @ObservationIgnored private var customImage: CGImage?
    @ObservationIgnored private var customImageError: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `imagesDirectory` defaults to `~/Library/Application Support/sTools/Images`; pass a temp
    /// directory in tests.
    public init(services: ToolServices, imagesDirectory: URL = SettingsStore.defaultDirectory().appending(path: "Images", directoryHint: .isDirectory)) {
        self.services = services
        self.imagesDirectory = imagesDirectory
        settings = services.settings.load(CrosshairSettings.self)
        loadCustomImageIfNeeded()
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            observeChanges()
            refreshIfEnabled()
        } else {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            panel.hide()
        }
    }

    /// Imports a user-chosen image into the sTools support folder and switches to the Image shape.
    public func importImage(from url: URL) {
        let result = CrosshairImageImport.importImage(from: url, into: imagesDirectory)
        switch result {
        case .success(let relativeName):
            settings.imageName = relativeName
            settings.shape = .image
            customImageError = nil
            loadCustomImage(named: relativeName)
        case .failure(let error):
            customImageError = error.message
        }
    }

    public var imageImportError: String? { customImageError }

    /// The loaded custom image, for the settings view's live preview.
    public var previewImage: CGImage? { customImage }

    /// Resets every setting to its shipped default.
    public func resetToDefault() {
        settings = CrosshairSettings.defaultValue
    }

    // MARK: - Placement

    private func observeChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfEnabled() }
        })
    }

    private func refreshIfEnabled() {
        guard isEnabled else { return }
        guard let display = targetDisplay() else {
            panel.hide()
            return
        }
        if settings.visibleOnlyWhileMinecraftFocused, services.minecraft.active?.isFrontmost != true {
            panel.hide()
            return
        }
        let sprite = currentSprite()
        let placement = CrosshairGeometry.placement(
            displayFrame: display.frame, scale: display.backingScale,
            spriteSize: sprite.size, hotPixel: sprite.hot,
            offsetX: settings.offsetX, offsetY: settings.offsetY, side: settings.centerSide)
        panel.setContent(CrosshairOverlayView(image: sprite.image, spriteOrigin: placement.spriteOrigin, canvasSize: placement.canvasSize))
        panel.show(frame: placement.windowFrame)
    }

    private func currentSprite() -> CrosshairSprite {
        if settings.shape == .image, let customImage {
            return CrosshairRenderer.image(customImage, settings: settings)
        }
        return CrosshairRenderer.builtIn(settings: settings)
    }

    private func targetDisplay() -> DisplayInfo? {
        switch settings.displayChoice {
        case .followMinecraft:
            if let id = services.minecraft.active?.displayID, let display = services.displays.displays.first(where: { $0.id == id }) {
                return display
            }
            return services.displays.main
        case .specific:
            if let id = settings.specificDisplayID, let display = services.displays.displays.first(where: { $0.id == id }) {
                return display
            }
            return services.displays.main
        }
    }

    private func loadCustomImageIfNeeded() {
        guard let name = settings.imageName else { return }
        loadCustomImage(named: name)
    }

    private func loadCustomImage(named name: String) {
        let url = imagesDirectory.appending(path: (name as NSString).lastPathComponent)
        customImage = CrosshairImageImport.loadImage(at: url)
    }
}
