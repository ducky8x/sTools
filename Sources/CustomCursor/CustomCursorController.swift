import AppKit
import Crosshair
import Observation
import STPlatform

/// Owns the Custom Cursor tool (spec 5.7): applies the pointer while the tool is on and its condition holds, and restores
/// macOS's arrow when it stops holding. It swaps only on a change (the switch, Minecraft coming to or leaving the front, a
/// setting); nothing runs on a timer.
@MainActor
@Observable
public final class CustomCursorController: ToolController {
    public private(set) var isEnabled = false
    /// Whether sTools' pointer is registered with macOS right now.
    public private(set) var isApplied = false
    public var settings: CustomCursorSettings {
        didSet {
            guard settings != oldValue else { return }
            services.settings.save(settings)
            refresh()
        }
    }
    public private(set) var imageImportError: String?

    @ObservationIgnored private let services: ToolServices
    @ObservationIgnored private let swapper: any CursorSwapping
    @ObservationIgnored let files: CursorFiles
    @ObservationIgnored private let imagesDirectory: URL
    /// The chosen image, read once, and a count that goes up with each load so a new image always draws again.
    @ObservationIgnored private var customImage: CGImage?
    @ObservationIgnored private var imageGeneration = 0
    /// macOS's arrow as it was when sTools' was applied, to put back.
    @ObservationIgnored private var originals: [RegisteredCursor] = []
    /// What's applied now, so a look that changes nothing swaps nothing.
    @ObservationIgnored private var appliedKey: ArtKey?
    @ObservationIgnored private var drawn: (key: ArtKey, cursor: CursorImage?)?
    @ObservationIgnored private var isWatchingMinecraft = false
    /// How many times the tool looked at whether to apply. For tests.
    @ObservationIgnored private(set) var lookCount = 0
    @ObservationIgnored private let log = STLog.logger("CustomCursor")

    /// What the pointer is drawn from.
    private struct ArtKey: Equatable {
        var settings: CustomCursorSettings
        var imageGeneration: Int
    }

    /// Restores a pointer a crash or a force quit left applied, before anything else (spec 5.7.1). The tool's files live
    /// in the settings store's folder, so a test's store keeps them in its temporary folder.
    public init(services: ToolServices, swapper: any CursorSwapping) {
        self.services = services
        self.swapper = swapper
        files = CursorFiles(supportDirectory: services.settings.directory)
        imagesDirectory = services.settings.directory.appending(path: SettingsLayout.imagesFolderName, directoryHint: .isDirectory)
        settings = services.settings.load(CustomCursorSettings.self)
        if swapper.isSupported, files.hasMarker {
            log.notice("Found the pointer applied by the last run; restoring it")
            swapper.restore(files.loadOriginals())
            files.removeMarker()
        }
        loadCustomImage()
    }

    /// Whether this macOS has the calls the tool needs. Without them it can't switch on.
    public var isSupported: Bool { swapper.isSupported }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled, !enabled || isSupported else { return }
        isEnabled = enabled
        if enabled {
            if !isWatchingMinecraft { watchMinecraft() }
            refresh()
        } else {
            restorePointer()
        }
    }

    /// Puts macOS's arrow back now, if sTools' is applied: for switching off, quitting and Reset sTools.
    public func restorePointer() {
        guard isApplied else { return }
        swapper.restore(originals.isEmpty ? files.loadOriginals() : originals)
        files.removeMarker()
        isApplied = false
        appliedKey = nil
        originals = []
    }

    /// Imports a chosen image into the support folder's Images, as the Crosshair does, and switches to the Image shape,
    /// clicking at its top left.
    public func importImage(from url: URL) {
        switch CrosshairShapes.importImage(from: url, into: imagesDirectory) {
        case .success(let name):
            imageImportError = nil
            var changed = settings
            changed.imageName = name
            changed.shape = .image
            changed.clickPoint = .topLeft
            // Loaded before the settings change, so the change draws the new image.
            loadCustomImage(named: name)
            settings = changed
        case .failure(let error):
            imageImportError = error.message
        }
    }

    public func resetToDefault() {
        settings = .defaultValue
    }

    /// The pointer as drawn for the page's preview, at one scale: the display's.
    public func preview(scale: Int) -> CursorImage? {
        CursorArt.cursor(for: settings, image: customImage, scales: [scale])
    }

    /// Whether it's on, applied now, where, and whether this macOS has the calls, for Copy Diagnostics.
    public var diagnosticsSummary: String {
        [isEnabled ? "On" : "Off", isApplied ? "applied now" : "not applied", settings.where.title,
         isSupported ? "calls found" : "calls missing"].joined(separator: ", ")
    }

    // MARK: Applying

    private var conditionHolds: Bool {
        switch settings.where {
        case .everywhere: true
        case .whileMinecraftInFront: services.minecraft.active?.isFrontmost == true
        }
    }

    /// Applies or restores to match the switch, the condition and the settings; does nothing when that's what's there.
    private func refresh() {
        lookCount += 1
        guard isEnabled, isSupported, conditionHolds, let cursor = currentCursor() else {
            restorePointer()
            return
        }
        let key = ArtKey(settings: settings, imageGeneration: imageGeneration)
        if isApplied, appliedKey == key { return }
        if !isApplied {
            // Read only while nothing of sTools' is registered, so the copy is always macOS's own (or another app's).
            let copies = CursorNames.arrow.compactMap(swapper.registered)
            do {
                try files.saveOriginals(copies)
                try files.writeMarker()
            } catch {
                log.error("Couldn't write the pointer's files, so it wasn't applied: \(error.localizedDescription, privacy: .public)")
                return
            }
            originals = copies
        }
        swapper.apply(cursor, names: CursorNames.arrow)
        isApplied = true
        appliedKey = key
    }

    /// The pointer at every scale, drawn once per change of what it's drawn from.
    private func currentCursor() -> CursorImage? {
        let key = ArtKey(settings: settings, imageGeneration: imageGeneration)
        if let drawn, drawn.key == key { return drawn.cursor }
        let cursor = CursorArt.cursor(for: settings, image: customImage)
        drawn = (key, cursor)
        return cursor
    }

    /// Minecraft's place in front is `@Observable`; this re-arms itself after every change while the tool is on, and
    /// ends once it's off.
    private func watchMinecraft() {
        isWatchingMinecraft = true
        withObservationTracking {
            _ = services.minecraft.active
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isWatchingMinecraft = false
                guard isEnabled else { return }
                refresh()
                watchMinecraft()
            }
        }
    }

    private func loadCustomImage(named name: String? = nil) {
        guard let name = name ?? settings.imageName else { return }
        customImage = CrosshairShapes.loadImage(at: imagesDirectory.appending(path: (name as NSString).lastPathComponent))
        imageGeneration += 1
    }
}
