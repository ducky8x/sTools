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

/// What an animated fill plays on and listens to. Tests pass fakes; the app uses `live`.
@MainActor
struct BackdropPlaybackEnvironment {
    /// Makes the player for the file at the URL.
    var makePlayer: (URL, any BackdropFrameClock) -> any BackdropPlayer
    /// A GIF's frame timer, and the timer that lets a replaced fill's player go once its crossfade is over.
    var clock: any BackdropFrameClock
    /// Whether some of a panel can be seen: it's ordered in and the window server doesn't call it wholly covered (by
    /// Minecraft's window, another Space, a locked or sleeping screen). Asked only when the system says it changed.
    var windowCanBeSeen: (NSWindow) -> Bool
    /// Where `screensDidSleep` and `screensDidWake` come from.
    var workspaceNotifications: NotificationCenter
    /// Where a panel's `didChangeOcclusionState` comes from.
    var windowNotifications: NotificationCenter

    static var live: BackdropPlaybackEnvironment {
        BackdropPlaybackEnvironment(
            makePlayer: { BackdropAnimationFile.makePlayer(for: $0, clock: $1) },
            clock: DispatchFrameClock(),
            // A panel that isn't ordered in has nothing covering it; the controller knows by its own record when a panel
            // is shown, so this is only the window server's word on a panel that is.
            windowCanBeSeen: { !$0.isVisible || $0.occlusionState.contains(.visible) },
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            windowNotifications: .default)
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
            forgetUnusedAnimations(from: oldValue)
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
    @ObservationIgnored private let playback: BackdropPlaybackEnvironment
    @ObservationIgnored private var panels: [UInt32: OverlayPanel] = [:]
    /// Imported images by name, loaded when first drawn or previewed and let go when the tool switches off. A
    /// screen-sized image is tens of megabytes once decoded. A name that didn't load maps to nil. An animated fill's
    /// first frame, for the page's preview, is kept here under the animation's name.
    @ObservationIgnored private var images: [String: CGImage?] = [:]
    @ObservationIgnored private var loadingPosters: Set<String> = []
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

    // An animated fill plays only while it can be seen: its panel is ordered in, and neither the screens nor the window
    // server say otherwise. These are what `updatePlayback()` weighs.
    /// The displays whose panel is ordered in now.
    @ObservationIgnored private var shownDisplays: Set<UInt32> = []
    /// The displays whose panel the window server reports wholly covered.
    @ObservationIgnored private var coveredDisplays: Set<UInt32> = []
    @ObservationIgnored private var screensAreAsleep = false
    @ObservationIgnored private var windowObservers: [UInt32: NSObjectProtocol] = [:]
    /// Players of fills that a new fill replaced, paused on their last picture while that fades out.
    @ObservationIgnored private var retiring: [Retiring] = []
    /// Which watch on the theme's motion setting is current; a new one ends the old.
    @ObservationIgnored private var motionWatch = 0

    /// Why an animation can't be played, by the name it's stored under: the page says so.
    private(set) var animationProblems: [String: String] = [:]
    /// What each animation turned out to be when its first frame was read, by the name it's stored under.
    private(set) var animationKinds: [String: BackdropAnimationFile.Kind] = [:]
    private var mainAnimationImportError: String?
    private var animationImportErrorsByDisplay: [UInt32: String] = [:]
    /// Counts the first frames that have come in, so the page draws them.
    private var posterRevision = 0

    private struct DrawnFill: Equatable {
        var fill: BackdropSettings.Fill
        var opacityPercent: Int
        var hasImage: Bool
    }

    private struct Retiring {
        let player: any BackdropPlayer
        let timer: any BackdropFrameTimer
    }

    /// `imagesDirectory` defaults to `~/Library/Application Support/sTools/Images`; pass a temp
    /// directory in tests.
    public convenience init(
        services: ToolServices,
        imagesDirectory: URL = SettingsStore.defaultDirectory().appending(path: "Images", directoryHint: .isDirectory),
        theme: STTheme? = nil
    ) {
        self.init(services: services, imagesDirectory: imagesDirectory, showsPanels: true, theme: theme, playback: .live)
    }

    /// Tests pass `showsPanels: false`: panels still get their content and frame, but are never ordered onto a
    /// screen.
    init(services: ToolServices, imagesDirectory: URL, showsPanels: Bool, theme: STTheme? = nil,
         playback: BackdropPlaybackEnvironment = .live) {
        self.services = services
        self.theme = theme
        self.imagesDirectory = imagesDirectory
        self.showsPanels = showsPanels
        self.playback = playback
        settings = services.settings.load(BackdropSettings.self)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            screensAreAsleep = false
            observeChanges()
            watchMotion()
            reconcile()
        } else {
            motionWatch += 1
            for observer in observers { removeObserver(observer) }
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

    // MARK: - Animated fills

    /// What the page says under the main fill's animation when its file couldn't be chosen: it can't be played, or is too
    /// big.
    public var animationImportError: String? { mainAnimationImportError }

    /// The same for `displayID`'s override fill.
    public func animationImportError(for displayID: UInt32) -> String? { animationImportErrorsByDisplay[displayID] }

    /// What the page says about a fill that is Animated when its file can't be played: it was moved, deleted or damaged
    /// since it was chosen. Nil while it's fine, and for any other kind of fill.
    public func animationProblem(for fill: BackdropSettings.Fill) -> String? {
        guard fill.kind == .animated, let name = fill.animationName else { return nil }
        return animationProblems[name]
    }

    /// Whether a fill's animation is a GIF or a video, once its first frame has been read (the page asks for that by
    /// drawing the fill's preview).
    func animationKind(for fill: BackdropSettings.Fill) -> BackdropAnimationFile.Kind? {
        guard fill.kind == .animated, let name = fill.animationName else { return nil }
        return animationKinds[name]
    }

    /// Imports a GIF or video for the main fill (Minecraft's display) and makes the fill Animated. The file is checked and
    /// copied off the main actor; a file that can't be played leaves the fill as it was and sets `animationImportError`.
    public func importAnimation(from url: URL) async {
        switch await BackdropAnimationFile.importAnimation(from: url, into: imagesDirectory) {
        case .success(let name):
            var fill = settings.fill
            fill.animationName = name
            fill.kind = .animated
            settings.fill = fill
            mainAnimationImportError = nil
        case .failure(let error):
            mainAnimationImportError = error.message
        }
    }

    /// Imports a GIF or video for `displayID`'s override fill, creating the override if needed.
    public func importAnimation(from url: URL, forDisplayID displayID: UInt32) async {
        switch await BackdropAnimationFile.importAnimation(from: url, into: imagesDirectory) {
        case .success(let name):
            var fill = settings.fill(for: displayID)
            fill.animationName = name
            fill.kind = .animated
            setDisplayFill(fill, for: displayID)
            animationImportErrorsByDisplay[displayID] = nil
        case .failure(let error):
            animationImportErrorsByDisplay[displayID] = error.message
        }
    }

    private func animationURL(_ name: String) -> URL {
        imagesDirectory.appending(path: (name as NSString).lastPathComponent)
    }

    /// An animation's first frame is looked for the first time the page or the panel asks, off the main actor; asking
    /// again meanwhile starts nothing. The page reads `posterRevision`, so it draws the frame when it's in.
    private func loadPosterIfNeeded(_ name: String) {
        guard images[name] == nil, !loadingPosters.contains(name) else { return }
        loadingPosters.insert(name)
        let url = animationURL(name)
        Task { [weak self] in
            let result = await BackdropAnimationFile.probe(url)
            self?.finishPoster(name, result)
        }
    }

    private func finishPoster(_ name: String, _ result: Result<BackdropAnimationFile.Info, BackdropImageImport.ImportError>) {
        loadingPosters.remove(name)
        switch result {
        case .success(let info):
            images[name] = info.poster
            animationKinds[name] = info.kind
            animationProblems[name] = nil
        case .failure:
            images[name] = .some(nil)
            animationProblems[name] = BackdropPlayerMessages.cantPlay
        }
        posterRevision += 1
    }

    /// Deletes the copy of an animation that no fill refers to any more, so replaced and reset animations don't pile up
    /// in the Images folder (a video is far larger than an image).
    private func forgetUnusedAnimations(from previous: BackdropSettings) {
        let before = Set(([previous.fill] + previous.displayFills.map(\.fill)).compactMap(\.animationName))
        let after = Set(([settings.fill] + settings.displayFills.map(\.fill)).compactMap(\.animationName))
        for name in before.subtracting(after) {
            images[name] = nil
            animationProblems[name] = nil
            animationKinds[name] = nil
            let url = animationURL(name)
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Fills

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

    /// The picture for a fill: an Image fill's image, or an Animated fill's first frame (looked for off the main actor,
    /// so it's nil until it arrives and the page draws again then). Loaded and kept on first use.
    func image(for fill: BackdropSettings.Fill) -> CGImage? {
        if fill.kind == .animated {
            guard let name = fill.animationName else { return nil }
            _ = posterRevision
            loadPosterIfNeeded(name)
            return images[name] ?? nil
        }
        guard let name = fill.imageName else { return nil }
        loadImageIfNeeded(name)
        return images[name] ?? nil
    }

    // MARK: - Placement

    private func observeChanges() {
        let workspaceCenter = playback.workspaceNotifications
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        // An animated fill stops while the screens sleep and carries on when they wake.
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAreAsleep = true
                self?.updatePlayback()
            }
        })
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAreAsleep = false
                self?.updatePlayback()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        watchMinecraft()
    }

    /// Removes an observer from whichever center it was added to.
    private func removeObserver(_ observer: NSObjectProtocol) {
        playback.workspaceNotifications.removeObserver(observer)
        NotificationCenter.default.removeObserver(observer)
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
        defer { updatePlayback() }
        uncoverPanelsTheWindowServerNoLongerCalls()
        if services.minecraft.active == nil, let standIn,
           let display = services.displays.displays.first(where: { $0.id == standIn.displayID }) {
            let panel = panel(for: display.id)
            draw(settings.fill(for: display.id), in: panel, displayID: display.id)
            show(panel, displayID: display.id, frame: display.frame, below: standIn.windowNumber)
            for displayID in panels.keys where displayID != display.id { hide(displayID) }
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
                hide(plan.displayID)
                continue
            }
            let panel = panel(for: plan.displayID)
            draw(settings.fill(for: plan.displayID), in: panel, displayID: plan.displayID)
            show(panel, displayID: plan.displayID, frame: display.frame, below: Int(belowWindowNumber))
        }
        for displayID in panels.keys where !covered.contains(displayID) {
            hide(displayID)
        }
    }

    private func show(_ panel: OverlayPanel, displayID: UInt32, frame: CGRect, below windowNumber: Int) {
        shownDisplays.insert(displayID)
        if showsPanels {
            panel.showBelow(frame: frame, windowNumber: windowNumber)
        } else {
            panel.moveTo(frame: frame)
        }
    }

    private func hide(_ displayID: UInt32) {
        shownDisplays.remove(displayID)
        // Out of sight, a panel counts as covered no longer: when it's ordered in again it is seen until the window server
        // says it isn't.
        coveredDisplays.remove(displayID)
        panels[displayID]?.hide()
    }

    /// Gives `panel` the fill, unless it already shows exactly that. A new fill crossfades from the old one over
    /// *Fill transition* (spec 5.2.4); the opacity changes at once.
    private func draw(_ fill: BackdropSettings.Fill, in panel: OverlayPanel, displayID: UInt32) {
        // An Animated fill plays its file in the panel; its first frame is only for the page's preview.
        let image = fill.kind == .animated ? nil : image(for: fill)
        let drawn = DrawnFill(fill: fill, opacityPercent: settings.opacityPercent, hasImage: image != nil)
        guard drawnFills[displayID] != drawn else { return }
        let opacity = Double(settings.opacityPercent) / 100
        if let layers = layers[displayID] {
            let previous = drawnFills[displayID]
            layers.opacity = opacity
            if previous?.fill != fill || previous?.hasImage != (image != nil) {
                if let previousFill = previous?.fill, Self.isSameAnimation(previousFill, fill) {
                    // The same file with another fit or background: the movie carries on, there is nothing to fade.
                    layers.update(fill)
                } else {
                    let player = makePlayer(for: fill)
                    let seconds = fillTransitionSeconds
                    var replaced: (any BackdropPlayer)?
                    STMotion.animate(.easeInOut(duration: seconds), reduce: seconds == 0) {
                        replaced = layers.show(fill, image: image, player: player)
                    }
                    if let replaced { retire(replaced) }
                }
            }
        } else {
            let layers = BackdropLayers(fill: fill, image: image, player: makePlayer(for: fill), opacity: opacity)
            self.layers[displayID] = layers
            panel.setContent(BackdropCrossfadeView(layers: layers))
        }
        drawnFills[displayID] = drawn
        drawCount += 1
    }

    /// Whether two fills play the same animation file, so a change between them is only in how it's fitted.
    private static func isSameAnimation(_ old: BackdropSettings.Fill, _ new: BackdropSettings.Fill) -> Bool {
        old.kind == .animated && new.kind == .animated && old.animationName != nil && old.animationName == new.animationName
    }

    /// How long a fill change crossfades: none while motion is reduced, when an animated fill also holds still on its
    /// first frame (`updatePlayback()`).
    var fillTransitionSeconds: Double {
        theme?.reduceMotion == true ? 0 : settings.fillTransitionSeconds
    }

    /// The fill a display's panel shows now, for tests.
    func shownFill(on displayID: UInt32) -> BackdropSettings.Fill? { layers[displayID]?.current.fill }

    // MARK: - Playing animated fills

    /// A player for an Animated fill's file, paused. It learns nothing yet: `updatePlayback()` starts it if the panel is
    /// being shown.
    private func makePlayer(for fill: BackdropSettings.Fill) -> (any BackdropPlayer)? {
        guard fill.kind == .animated, let name = fill.animationName else { return nil }
        let player = playback.makePlayer(animationURL(name), playback.clock)
        player.observe { [weak self, weak player] in
            guard let self, let player else { return }
            self.animationProblems[name] = player.failure
        }
        if let failure = player.failure { animationProblems[name] = failure }
        return player
    }

    /// Lets a replaced fill's player go: it stops at its last picture right away, which stays up while the fill fades
    /// out, and is stopped for good once the fade is over.
    private func retire(_ player: any BackdropPlayer) {
        player.pause()
        let timer = playback.clock.schedule(after: fillTransitionSeconds + 0.1) { [weak self] in
            player.stop()
            self?.retiring.removeAll { $0.player === player }
        }
        retiring.append(Retiring(player: player, timer: timer))
    }

    /// Plays each display's animated fill while it can be seen and stops it otherwise, which is the whole of its cost
    /// control: nothing plays, decodes or ticks while the backdrop is off, hidden (Minecraft minimized, full screen, not
    /// focused), covered, or its screen asleep. While motion is reduced (Settings ▸ Appearance ▸ Reduce animations, or
    /// macOS's Reduce motion) a fill that can be seen holds still on its first frame instead of playing (spec 3.4).
    func updatePlayback() {
        let reduced = theme?.reduceMotion == true
        for (displayID, layers) in layers {
            let canBeSeen = isEnabled && shownDisplays.contains(displayID) && !coveredDisplays.contains(displayID) && !screensAreAsleep
            layers.setPlayback(canBeSeen ? (reduced ? .firstFrame : .playing) : .paused)
        }
    }

    /// Plays or holds the animations again when motion is reduced or comes back, for as long as the tool is on. It re-arms
    /// itself after each change; the tool being switched off, or on again, ends the watch it belongs to.
    private func watchMotion() {
        guard let theme else { return }
        motionWatch += 1
        trackMotion(of: theme, watch: motionWatch)
    }

    private func trackMotion(of theme: STTheme, watch: Int) {
        withObservationTracking {
            _ = theme.reduceMotion
        } onChange: { [weak self] in
            // The change isn't made yet when this is called; the next turn of the main actor sees it.
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.motionWatch == watch else { return }
                self.updatePlayback()
                self.trackMotion(of: theme, watch: watch)
            }
        }
    }

    /// A panel marked covered is looked at again on every re-order. Only a notice marks one covered, so if the notice that
    /// it can be seen again never came, this puts it right at the next app switch. It never marks one covered: a panel
    /// ordered in a moment ago may not have its visibility yet, and only the window server's notice may say so.
    private func uncoverPanelsTheWindowServerNoLongerCalls() {
        for displayID in coveredDisplays {
            if let panel = panels[displayID], playback.windowCanBeSeen(panel) { coveredDisplays.remove(displayID) }
        }
    }

    /// The window server said a panel's visibility changed.
    func windowVisibilityChanged(for displayID: UInt32) {
        guard let panel = panels[displayID], shownDisplays.contains(displayID) else { return }
        if playback.windowCanBeSeen(panel) {
            coveredDisplays.remove(displayID)
        } else {
            coveredDisplays.insert(displayID)
        }
        updatePlayback()
    }

    /// The panel on `displayID`, if there is one. For tests.
    func existingPanel(for displayID: UInt32) -> OverlayPanel? { panels[displayID] }

    /// Whether `displayID`'s animated fill is playing now, or is held on its first frame. For tests.
    func isPlayingAnimation(on displayID: UInt32) -> Bool { layers[displayID]?.isPlayingAnimation ?? false }
    func isHoldingFirstFrame(on displayID: UInt32) -> Bool { layers[displayID]?.isHoldingFirstFrame ?? false }

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
        windowObservers[displayID] = playback.windowNotifications.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowVisibilityChanged(for: displayID) }
        }
        return panel
    }

    /// Switching off closes the panels instead of only hiding them: a hidden panel would keep its full-screen layer
    /// and image in memory for nothing. Switching on again builds them anew. Every animation stops and lets go.
    private func releasePanels() {
        for layers in layers.values { layers.stopPlayer() }
        for retired in retiring {
            retired.timer.cancel()
            retired.player.stop()
        }
        retiring.removeAll()
        for observer in windowObservers.values { playback.windowNotifications.removeObserver(observer) }
        windowObservers.removeAll()
        for panel in panels.values {
            panel.hide()
            panel.close()
        }
        panels.removeAll()
        shownDisplays.removeAll()
        coveredDisplays.removeAll()
        drawnFills.removeAll()
        layers.removeAll()
        images.removeAll()
        loadingPosters.removeAll()
    }

    private func loadImageIfNeeded(_ name: String?) {
        guard let name, images[name] == nil else { return }
        let url = imagesDirectory.appending(path: (name as NSString).lastPathComponent)
        images[name] = BackdropImageImport.loadImage(at: url)
    }
}

/// What an animated fill's player is told to do.
enum BackdropPlaybackState: Equatable {
    /// Stopped where it is: the panel is hidden, covered or its screens asleep.
    case paused
    /// On its first frame and not playing, while motion is reduced (spec 3.4).
    case firstFrame
    case playing
}

/// What one backdrop panel shows. A new fill gets a new id, so SwiftUI crossfades from the old layer to it.
@MainActor
@Observable
final class BackdropLayers {
    struct Layer {
        var id: Int
        var fill: BackdropSettings.Fill
        var image: CGImage?
        /// Plays an Animated fill's file; nil for every other fill.
        var player: (any BackdropPlayer)?
    }

    private(set) var current: Layer
    var opacity: Double
    /// What the player has been told to do. Not observed: the player is driven directly, because a SwiftUI view in a
    /// window that isn't on screen may not update until it is.
    @ObservationIgnored private(set) var playbackState: BackdropPlaybackState = .paused

    /// Whether the fill is an animation and it is playing.
    var isPlayingAnimation: Bool { playbackState == .playing && current.player != nil }
    /// Whether the fill is an animation held on its first frame.
    var isHoldingFirstFrame: Bool { playbackState == .firstFrame && current.player != nil }

    init(fill: BackdropSettings.Fill, image: CGImage?, player: (any BackdropPlayer)? = nil, opacity: Double) {
        current = Layer(id: 0, fill: fill, image: image, player: player)
        self.opacity = opacity
    }

    /// Puts a new fill up and returns the player of the one it replaced, which is left as it was.
    @discardableResult
    func show(_ fill: BackdropSettings.Fill, image: CGImage?, player: (any BackdropPlayer)? = nil) -> (any BackdropPlayer)? {
        let replaced = current.player
        current = Layer(id: current.id + 1, fill: fill, image: image, player: player)
        playbackState = .paused
        return replaced
    }

    /// The same picture fitted another way: no new layer, so nothing fades and the animation goes on.
    func update(_ fill: BackdropSettings.Fill) {
        current.fill = fill
    }

    /// Tells the current fill's player what to do, when that changes anything.
    func setPlayback(_ state: BackdropPlaybackState) {
        guard state != playbackState else { return }
        playbackState = state
        switch state {
        case .playing: current.player?.play()
        case .firstFrame: current.player?.showFirstFrame()
        case .paused: current.player?.pause()
        }
    }

    func stopPlayer() {
        playbackState = .paused
        current.player?.stop()
    }
}

/// The backdrop panel's content: the current fill, crossfading from the last one when it changes.
struct BackdropCrossfadeView: View {
    let layers: BackdropLayers

    var body: some View {
        ZStack {
            BackdropFillView(fill: layers.current.fill, image: layers.current.image, player: layers.current.player)
                .id(layers.current.id)
                .transition(.opacity)
        }
        .opacity(layers.opacity)
    }
}
