import AppKit
import Observation
import STDesign
import STPlatform

/// Owns the Crosshair tool's state and its one on-screen overlay.
///
/// With Hide in Minecraft's menus or Be the pointer in Minecraft's menus on, it also watches the pointer while the tool is
/// on and Minecraft is in front: Minecraft hides the pointer in the game and shows it in its menus, inventories and pause
/// screen, so a pointer that shows means a menu and the overlay hides until it's hidden again. Being the pointer also
/// turns macOS's arrow into the crosshair for as long as Minecraft is in front, and puts the arrow back whenever that
/// stops: Minecraft leaving the front, the tool or the setting off, quitting, Reset sTools.
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
    /// The overlay's one window. Internal so tests can read back its frame and content.
    @ObservationIgnored let panel = OverlayPanel(role: .topmost)
    @ObservationIgnored private let showsPanel: Bool
    @ObservationIgnored private var customImage: CGImage?
    @ObservationIgnored private var customImageError: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isWatchingMinecraft = false
    /// How many times the overlay's visibility and place were worked out, and whether it's up. For tests.
    @ObservationIgnored private(set) var placementCount = 0
    @ObservationIgnored private(set) var isOverlayShown = false
    /// How many times the crosshair was drawn into the panel. For tests.
    @ObservationIgnored private(set) var drawCount = 0
    /// What the panel shows now and where, so a refresh that changes neither (Minecraft gaining or losing focus,
    /// another app's window moving) leaves the overlay's content alone instead of drawing it again.
    @ObservationIgnored private var drawn: (key: DrawnCrosshair, frame: CGRect)?
    /// Counts custom image loads, so a new image always draws again.
    @ObservationIgnored private var imageGeneration = 0
    /// The sprite the panel shows now, which the pointer is drawn from too. Internal so tests can compare the two.
    @ObservationIgnored private(set) var sprite: CrosshairSprite?

    /// Swaps macOS's arrow for the crosshair, and watches whether the pointer shows. Nil without them: the menu settings
    /// then do nothing.
    @ObservationIgnored private let pointer: PointerSwap?
    @ObservationIgnored private let pointerWatch: (any PointerVisibilityWatching)?
    /// Whether the pointer shows, as the watch last said; nil while it isn't watching.
    @ObservationIgnored private(set) var pointerShows: Bool?
    /// What the arrow was last drawn from, so a change that leaves the look alone swaps nothing.
    @ObservationIgnored private var appliedLook: PointerLook?
    /// Set as sTools quits or resets: from then on the arrow stays macOS's.
    @ObservationIgnored private var pointerIsRetired = false
    @ObservationIgnored private var isRefreshing = false

    private struct DrawnCrosshair: Equatable {
        var settings: CrosshairSettings
        var displayFrame: CGRect
        var scale: CGFloat
        var imageGeneration: Int
    }

    /// What the pointer is drawn from: the settings that change how the crosshair looks, the display's scale and the
    /// image. Where it sits on the screen and when it shows don't change the pointer.
    private struct PointerLook: Equatable {
        var settings: CrosshairSettings
        var scale: Int
        var imageGeneration: Int

        init(_ settings: CrosshairSettings, scale: Int, imageGeneration: Int) {
            var look = settings
            let defaults = CrosshairSettings.defaultValue
            look.offsetX = defaults.offsetX
            look.offsetY = defaults.offsetY
            look.visibleOnlyWhileMinecraftFocused = defaults.visibleOnlyWhileMinecraftFocused
            look.hidesInMinecraftMenus = defaults.hidesInMinecraftMenus
            look.isPointerInMinecraftMenus = defaults.isPointerInMinecraftMenus
            look.displayChoice = defaults.displayChoice
            look.specificDisplayID = defaults.specificDisplayID
            self.settings = look
            self.scale = scale
            self.imageGeneration = imageGeneration
        }
    }

    /// `imagesDirectory` defaults to `~/Library/Application Support/sTools/Images`; pass a temp directory in tests.
    /// `pointer` and `pointerWatch` make the menu settings work: the app passes the live ones, and tests fakes.
    public convenience init(
        services: ToolServices,
        imagesDirectory: URL = SettingsStore.defaultDirectory().appending(path: "Images", directoryHint: .isDirectory),
        pointer: PointerSwap? = nil, pointerWatch: (any PointerVisibilityWatching)? = nil
    ) {
        self.init(services: services, imagesDirectory: imagesDirectory, showsPanel: true, pointer: pointer,
                  pointerWatch: pointerWatch)
    }

    /// Tests pass `showsPanel: false`: the panel still gets its content and frame, but is never ordered
    /// onto a screen.
    init(services: ToolServices, imagesDirectory: URL, showsPanel: Bool, pointer: PointerSwap? = nil,
         pointerWatch: (any PointerVisibilityWatching)? = nil) {
        self.services = services
        self.imagesDirectory = imagesDirectory
        self.showsPanel = showsPanel
        self.pointer = pointer
        self.pointerWatch = pointerWatch
        settings = services.settings.load(CrosshairSettings.self)
        loadCustomImageIfNeeded()
    }

    /// Whether Hide in Minecraft's menus can work here: this macOS says whether the pointer shows.
    public var canHideInMinecraftMenus: Bool { pointerWatch?.isSupported == true }
    /// Whether Be the pointer in Minecraft's menus can work here: the pointer can be watched and swapped.
    public var canBeThePointer: Bool { canHideInMinecraftMenus && pointer?.isSupported == true }
    /// Whether macOS's arrow is the crosshair right now.
    public var isThePointer: Bool { pointer?.isApplied == true }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            observeChanges()
            refreshIfEnabled()
        } else {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            leaveTheMenus()
            hidePanel()
        }
    }

    /// Puts macOS's arrow back for the rest of this run, whatever the switch and settings say: for quitting and Reset
    /// sTools. A swapped arrow outlives sTools, and after a reset the settings in memory are stale.
    public func restorePointerForGood() {
        pointerIsRetired = true
        leaveTheMenus()
    }

    /// Imports a user-chosen image into the sTools support folder and switches to the Image shape.
    public func importImage(from url: URL) {
        let result = CrosshairImageImport.importImage(from: url, into: imagesDirectory)
        switch result {
        case .success(let relativeName):
            customImageError = nil
            // Loaded before the settings change, so the change draws the new image, in the overlay and the pointer.
            loadCustomImage(named: relativeName)
            var changed = settings
            changed.imageName = relativeName
            changed.shape = .image
            settings = changed
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
        if !isWatchingMinecraft { watchMinecraft() }
    }

    /// Minecraft's focus and display, and the display list, are `@Observable`; this re-arms itself after
    /// every change while the tool is on, so "Show only while Minecraft is focused" and Follow Minecraft
    /// react as soon as Minecraft changes.
    private func watchMinecraft() {
        isWatchingMinecraft = true
        withObservationTracking {
            _ = services.minecraft.active
            _ = services.displays.displays
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isWatchingMinecraft = false
                guard isEnabled else { return }
                refreshIfEnabled()
                watchMinecraft()
            }
        }
    }

    private func refreshIfEnabled() {
        guard isEnabled else { return }
        placementCount += 1
        isRefreshing = true
        defer { isRefreshing = false }
        let minecraftInFront = services.minecraft.active?.isFrontmost == true
        guard let display = targetDisplay(), !settings.visibleOnlyWhileMinecraftFocused || minecraftInFront else {
            leaveTheMenus()
            hidePanel()
            return
        }
        let key = DrawnCrosshair(settings: settings, displayFrame: display.frame, scale: display.backingScale,
                                 imageGeneration: imageGeneration)
        let frame: CGRect
        let sprite: CrosshairSprite
        if let drawn, drawn.key == key, let current = self.sprite {
            frame = drawn.frame
            sprite = current
        } else {
            sprite = currentSprite()
            let placement = CrosshairGeometry.placement(
                displayFrame: display.frame, scale: display.backingScale,
                spriteSize: sprite.size, hotPixel: sprite.hot,
                offsetX: settings.offsetX, offsetY: settings.offsetY)
            panel.setContent(CrosshairOverlayView(
                image: sprite.image, spriteOrigin: placement.spriteOrigin, canvasSize: placement.canvasSize,
                scale: display.backingScale))
            frame = placement.windowFrame
            drawn = (key, frame)
            self.sprite = sprite
            drawCount += 1
        }

        // Minecraft's menus: watched only while a menu setting is on and Minecraft is in front.
        let watchesMenus = settings.hidesWhileThePointerShows && minecraftInFront && canHideInMinecraftMenus
        if watchesMenus {
            watchThePointer()
            if settings.isPointerInMinecraftMenus, canBeThePointer {
                becomeThePointer(sprite: sprite, scale: display.backingScale)
            } else {
                restoreThePointer()
            }
        } else {
            leaveTheMenus()
        }
        if watchesMenus, pointerShows == true {
            hidePanel()
            return
        }
        if showsPanel {
            panel.show(frame: frame)
        } else {
            panel.moveTo(frame: frame)
        }
        isOverlayShown = true
    }

    // MARK: - Minecraft's menus

    /// Starts watching the pointer, unless it's watching already. The first reading comes at once.
    private func watchThePointer() {
        guard let pointerWatch, !pointerWatch.isWatching else { return }
        pointerWatch.start { [weak self] shows in
            guard let self, pointerShows != shows else { return }
            pointerShows = shows
            // The first reading comes during the refresh that started the watch, which goes on to use it.
            if !isRefreshing { refreshIfEnabled() }
        }
    }

    /// Stops watching the pointer and puts macOS's arrow back.
    private func leaveTheMenus() {
        pointerWatch?.stop()
        pointerShows = nil
        restoreThePointer()
    }

    /// Makes macOS's arrow the crosshair, drawn from the overlay's sprite; does nothing when it already is, with this look.
    private func becomeThePointer(sprite: CrosshairSprite, scale: CGFloat) {
        guard let pointer, !pointerIsRetired else { return }
        let isImage = settings.shape == .image
        // The Image shape with no image draws nothing, and an invisible pointer would be no pointer at all.
        guard !isImage || customImage != nil else {
            restoreThePointer()
            return
        }
        let wholeScale = max(1, Int(scale.rounded()))
        let look = PointerLook(settings, scale: wholeScale, imageGeneration: imageGeneration)
        if pointer.isApplied, appliedLook == look { return }
        let click = CrosshairPointerArt.clickPoint(of: sprite, settings: settings, isImage: isImage)
        let cursor = CrosshairPointerArt.cursor(sprite: sprite, click: click, displayScale: wholeScale)
        if pointer.apply(cursor) { appliedLook = look }
    }

    private func restoreThePointer() {
        pointer?.restore()
        appliedLook = nil
    }

    private func hidePanel() {
        panel.hide()
        isOverlayShown = false
    }

    private func currentSprite() -> CrosshairSprite {
        if settings.shape == .image, let customImage {
            return CrosshairRenderer.image(customImage, settings: settings)
        }
        return CrosshairRenderer.builtIn(settings: settings)
    }

    /// The crosshair's display in pixels, or nil when there's no display.
    var displayPixelSize: PixelSize? {
        targetDisplay().map { CrosshairGeometry.gridSize(frame: $0.frame, scale: $0.backingScale) }
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
        imageGeneration += 1
    }
}
