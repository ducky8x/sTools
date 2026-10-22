import AppKit
import Observation
import STDesign
import STPlatform
import SwiftUI

// MARK: - The interface

/// The overlay as the controller drives it (plan, "Interfaces between tasks"). `TimerOverlayPresenter` is the live
/// one; tests pass a fake, so no test needs a window.
///
/// Frames are in AppKit global points. Each motion takes `reduceMotion` as the controller reads it from the app's
/// `STTheme` when the motion starts. While it's true the overlay appears and leaves at once and never pulses or
/// flashes (spec 3.4, 5.6.4).
@MainActor
public protocol TimerOverlayPresenting: AnyObject {
    /// Whether the overlay is up: from `popIn` until its exit has finished and its panel is gone.
    var isShowing: Bool { get }

    /// Where the plate is, or nil while nothing is up. When the plate's size changes while it's up (the *Paused* mark,
    /// the word at zero, another digit), it keeps its center and stays on its display, so this can differ from the
    /// frame passed in last.
    var plateFrame: CGRect? { get }

    /// The plate's size in whole points for `content` drawn in `settings`' look: what `popIn` and `move` expect.
    func plateSize(for content: TimerOverlayContent, settings: TimerOverlaySettings) -> CGSize

    /// Builds this pop-up's panel and pops the overlay in, its plate at `plateFrame`, on the display whose frame is
    /// `displayFrame`. The panel is left out of recordings and screen captures when Show in recordings is off, fixed
    /// for this pop-up. An overlay still up, or still leaving, is released at once first, and that exit's completion
    /// never runs: it didn't leave, a new pop-up came.
    func popIn(_ content: TimerOverlayContent, settings: TimerOverlaySettings, plateFrame: CGRect, displayFrame: CGRect,
               reduceMotion: Bool)

    /// Shows `content`, at once. Does nothing when it's what's shown, or when nothing is up.
    func update(_ content: TimerOverlayContent)

    /// Draws the overlay in `settings`' look from now on, as when the page changes it while the overlay is up; a
    /// change that doesn't touch the look redraws nothing. Pop-up motion and While ringing apply from the next motion,
    /// Show in recordings from the next pop-up.
    func update(settings: TimerOverlaySettings)

    /// Puts the plate at `plateFrame`, centered there in its own size, on the display whose frame is
    /// `displayFrame`. At once: the panel never animates.
    func move(plateFrame: CGRect, displayFrame: CGRect)

    /// One ring's pulse (1 → 1.06 → 1), or one quick flash, as While ringing says; nothing for the time's-up look
    /// alone, while motion is reduced, on the way out, or for a flash within a third of a second of the last.
    func pulse(reduceMotion: Bool)

    /// Pops the overlay out the way it came, releases its panel, then calls `completion`. At once, with the
    /// completion right away, while motion is reduced, with Pop-up motion none, or when nothing is up. A second call
    /// while it leaves adds its completion to the same exit.
    func popOut(reduceMotion: Bool, completion: @escaping @MainActor () -> Void)

    /// Placement mode (spec 5.6.5): on, the plate takes the mouse and shows a dashed outline, and each drag reports
    /// its translation from where it started (screen points, +x right, +y down) and then its end, as the NBB
    /// Overlay's view does. Off, the overlay is click-through again. It carries over to later pop-ups until it's
    /// turned off, and it never lets the panel take focus.
    func setPlacementMode(_ isOn: Bool, onDragChanged: @escaping @MainActor (CGSize) -> Void,
                          onDragEnded: @escaping @MainActor () -> Void)
}

// MARK: - The live overlay

/// The live overlay (spec 5.6.4, 5.6.10): a click-through topmost panel, built at each pop-up and released once the
/// overlay has left, so an idle timer has no window at all.
///
/// - The panel covers the plate and the margin its motion needs (`TimerMotion.margin`), never the display. It can't
///   be hidden, so it stays up through Hide sTools and Hide Others.
/// - Its SwiftUI content is set once per pop-up, with the app's theme in its environment and `stMotionRoot(theme)` at
///   its root, as the hotkey confirmation does. After that only the overlay's model changes, and only when what it
///   shows changes: outside the pop-in, the pop-out and the pulses the panel redraws once a second while counting.
/// - Every motion goes through `STMotion` and reads Reduce animations as it starts (the controller's flag or the
///   theme's). While motion is reduced nothing moves, and a pop-out releases the panel at once.
/// - A pop-out releases the panel when its animation reports its end, or at the latest a moment after it should
///   have ended, through the scheduler, so the end of a run never waits on a display that stopped drawing.
@MainActor
public final class TimerOverlayPresenter: TimerOverlayPresenting {
    private let theme: STTheme
    private let scheduler: any TimerScheduling
    private let clock: any TimerClock
    private let mouseLocation: @MainActor () -> CGPoint

    private var popUp: PopUp?
    private var placement: Placement?
    /// Where the mouse was when the current drag started, in screen points.
    private var dragStart: CGPoint?
    /// When the last flash started, on `clock`.
    private var lastFlash: TimeInterval?
    /// The last measurement, so a run of same-shape content is measured once.
    private var measured: (key: SizeKey, size: CGSize)?

    /// How long after a pop-out should have ended its backstop wake releases the panel anyway.
    static let exitBackstop: TimeInterval = 0.25

    /// How many times the plate was measured. For tests.
    private(set) var measureCount = 0
    /// How many pulses and flashes played. For tests.
    private(set) var beats = 0

    /// `theme` is the app's: its Increase Contrast draws the overlay and its Reduce animations stops the motion. The
    /// scheduler and clock are the timer's own (`TimerScheduling`, `TimerClock`).
    public convenience init(theme: STTheme, scheduler: any TimerScheduling = DispatchTimerScheduler(),
                            clock: any TimerClock = MonotonicClock()) {
        self.init(theme: theme, scheduler: scheduler, clock: clock, mouseLocation: { NSEvent.mouseLocation })
    }

    /// Tests also pass where the mouse is.
    init(theme: STTheme, scheduler: any TimerScheduling, clock: any TimerClock,
         mouseLocation: @escaping @MainActor () -> CGPoint) {
        self.theme = theme
        self.scheduler = scheduler
        self.clock = clock
        self.mouseLocation = mouseLocation
    }

    /// The panel up now. For tests.
    var panel: OverlayPanel? { popUp?.panel }
    /// The model the panel draws. For tests.
    var model: TimerOverlayModel? { popUp?.model }

    public var isShowing: Bool { popUp != nil }

    public var plateFrame: CGRect? { popUp?.plateFrame }

    public func plateSize(for content: TimerOverlayContent, settings: TimerOverlaySettings) -> CGSize {
        measure(content, style: TimerOverlayStyle(settings))
    }

    public func popIn(_ content: TimerOverlayContent, settings: TimerOverlaySettings, plateFrame: CGRect,
                      displayFrame: CGRect, reduceMotion: Bool) {
        if let popUp { release(popUp) }
        let plate = TimerOverlayGeometry.wholePoints(plateFrame)
        let reduce = reduceMotion || theme.reduceMotion
        let step = TimerMotion.popIn(settings.popUpMotion, from: TimerMotion.nearestEdge(of: plate, in: displayFrame),
                                     reduceMotion: reduce)
        let style = TimerOverlayStyle(settings)
        let model = TimerOverlayModel(content: content, style: style, isPlacing: placement != nil, pose: step.from)
        model.onDragChanged = { [weak self] in self?.dragChanged() }
        model.onDragEnded = { [weak self] in self?.dragEnded() }

        let panel = OverlayPanel(role: .topmost, isExcludedFromCapture: !settings.showsInRecordings)
        panel.canHide = false
        panel.isMouseHandlingEnabled = placement != nil
        panel.setContent(TimerOverlayPanelRoot(model: model).stMotionRoot(theme).environment(\.stTheme, theme))
        popUp = PopUp(panel: panel, model: model, settings: settings, plateFrame: plate, displayFrame: displayFrame,
                      sizeKey: sizeKey(content, style))
        // Drawn at the step's first pose as it's ordered in, so the motion starts from there.
        panel.show(frame: TimerOverlayGeometry.panelFrame(plate: plate))
        play(step) { model.pose = $0 }
    }

    public func update(_ content: TimerOverlayContent) {
        guard let popUp, popUp.model.content != content else { return }
        popUp.model.content = content
        fitPlate(popUp)
    }

    public func update(settings: TimerOverlaySettings) {
        guard let popUp else { return }
        popUp.settings = settings
        let style = TimerOverlayStyle(settings)
        guard style != popUp.model.style else { return }
        popUp.model.style = style
        fitPlate(popUp)
    }

    public func move(plateFrame: CGRect, displayFrame: CGRect) {
        guard let popUp else { return }
        let size = popUp.plateFrame.size
        let plate = TimerOverlayGeometry.wholePoints(CGRect(
            x: plateFrame.midX - size.width / 2, y: plateFrame.midY - size.height / 2, width: size.width, height: size.height))
        popUp.plateFrame = plate
        popUp.displayFrame = displayFrame
        popUp.panel.moveTo(frame: TimerOverlayGeometry.panelFrame(plate: plate))
    }

    public func pulse(reduceMotion: Bool) {
        guard let popUp, popUp.exit == nil else { return }
        let steps = TimerMotion.ring(popUp.settings.whileRinging, reduceMotion: reduceMotion || theme.reduceMotion)
        guard let first = steps.first else { return }
        if popUp.settings.whileRinging == .quickFlashes {
            let now = clock.now()
            // A hair of slack, so flashes exactly a third of a second apart still play.
            if let lastFlash, now - lastFlash < TimerMotion.minimumFlashInterval - 1e-6 { return }
            lastFlash = now
        }
        beats += 1
        play(first, change: { popUp.model.beat = $0 }) { [weak self, weak popUp] in
            guard let self, let popUp, self.popUp === popUp else { return }
            // Read again: Reduce animations may have come on since the pulse started, and then it ends at once.
            for step in steps.dropFirst() {
                self.play(self.theme.reduceMotion ? .still(step.to) : step) { popUp.model.beat = $0 }
            }
        }
    }

    public func popOut(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        guard let popUp else {
            completion()
            return
        }
        guard popUp.exit == nil else {
            popUp.exit?.completions.append(completion)
            return
        }
        let step = TimerMotion.popOut(
            popUp.settings.popUpMotion, toward: TimerMotion.nearestEdge(of: popUp.plateFrame, in: popUp.displayFrame),
            reduceMotion: reduceMotion || theme.reduceMotion)
        popUp.exit = Exit(completions: [completion])
        if step.animation != nil {
            popUp.exit?.backstop = scheduler.schedule(after: step.duration + Self.exitBackstop) { [weak self, weak popUp] in
                guard let self, let popUp else { return }
                self.finishExit(popUp)
            }
        }
        play(step, change: { popUp.model.pose = $0 }) { [weak self, weak popUp] in
            guard let self, let popUp else { return }
            self.finishExit(popUp)
        }
    }

    public func setPlacementMode(_ isOn: Bool, onDragChanged: @escaping @MainActor (CGSize) -> Void,
                                 onDragEnded: @escaping @MainActor () -> Void) {
        placement = isOn ? Placement(changed: onDragChanged, ended: onDragEnded) : nil
        if !isOn { dragStart = nil }
        guard let popUp else { return }
        popUp.panel.isMouseHandlingEnabled = isOn
        if popUp.model.isPlacing != isOn { popUp.model.isPlacing = isOn }
    }

    // MARK: - Private

    /// Plays `step`: from its first pose to its last with its `STMotion` token, or at once, with `completion` when
    /// it's over (at once when there's no animation, as `STMotion.animate` does).
    private func play(_ step: TimerMotion.Step, change: @escaping (TimerMotion.Pose) -> Void,
                      completion: (() -> Void)? = nil) {
        // The token is ignored while reduced; `STMotion.animate` then changes it at once and completes right away.
        let animation = step.animation ?? STMotion.quick
        let reduce = step.animation == nil
        if let completion {
            STMotion.animate(animation, reduce: reduce, { change(step.to) }, completion: completion)
        } else {
            STMotion.animate(animation, reduce: reduce) { change(step.to) }
        }
    }

    private func finishExit(_ popUp: PopUp) {
        guard self.popUp === popUp, let exit = popUp.exit else { return }
        release(popUp)
        for completion in exit.completions { completion() }
    }

    /// Orders the panel out and lets it go, with its model and any wake it had.
    private func release(_ popUp: PopUp) {
        popUp.exit?.backstop?.cancel()
        popUp.panel.hide()
        popUp.panel.contentView = nil
        if self.popUp === popUp {
            self.popUp = nil
            dragStart = nil
        }
    }

    /// Measures the plate again when what it shows may have changed its size, and grows or shrinks the panel around
    /// the plate's center.
    private func fitPlate(_ popUp: PopUp) {
        let key = sizeKey(popUp.model.content, popUp.model.style)
        guard key != popUp.sizeKey else { return }
        popUp.sizeKey = key
        let size = measure(popUp.model.content, style: popUp.model.style)
        guard size != popUp.plateFrame.size else { return }
        let plate = TimerOverlayGeometry.resized(popUp.plateFrame, to: size, within: popUp.displayFrame)
        popUp.plateFrame = plate
        popUp.panel.moveTo(frame: TimerOverlayGeometry.panelFrame(plate: plate))
    }

    private func measure(_ content: TimerOverlayContent, style: TimerOverlayStyle) -> CGSize {
        let key = sizeKey(content, style)
        if let measured, measured.key == key { return measured.size }
        measureCount += 1
        let view = TimerOverlayView(content: content, style: style).environment(\.stTheme, theme)
        let size = NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        measured = (key, size)
        return size
    }

    private func sizeKey(_ content: TimerOverlayContent, _ style: TimerOverlayStyle) -> SizeKey {
        SizeKey(content: content, style: style, increaseContrast: theme.increaseContrast)
    }

    private func dragChanged() {
        guard let placement else { return }
        let location = mouseLocation()
        let start = dragStart ?? location
        dragStart = start
        placement.changed(CGSize(width: location.x - start.x, height: start.y - location.y))
    }

    private func dragEnded() {
        guard dragStart != nil else { return }
        dragStart = nil
        placement?.ended()
    }
}

/// One pop-up, from `popIn` until its panel is released.
@MainActor
private final class PopUp {
    let panel: OverlayPanel
    let model: TimerOverlayModel
    var settings: TimerOverlaySettings
    var plateFrame: CGRect
    var displayFrame: CGRect
    /// What the plate's size was last worked out for.
    var sizeKey: SizeKey
    /// Set once the overlay starts to leave.
    var exit: Exit?

    init(panel: OverlayPanel, model: TimerOverlayModel, settings: TimerOverlaySettings, plateFrame: CGRect,
         displayFrame: CGRect, sizeKey: SizeKey) {
        self.panel = panel
        self.model = model
        self.settings = settings
        self.plateFrame = plateFrame
        self.displayFrame = displayFrame
        self.sizeKey = sizeKey
    }
}

/// An exit under way: who's waiting for it, and the wake that ends it if the animation never reports its end.
@MainActor
private struct Exit {
    var completions: [@MainActor () -> Void]
    var backstop: (any TimerScheduledWake)?
}

@MainActor
private struct Placement {
    let changed: @MainActor (CGSize) -> Void
    let ended: @MainActor () -> Void
}

/// What decides the plate's size: the text with every digit as 0 (the figures are tabular, so one digit is as wide
/// as another), the caption, whether a bar or ring shows, the look, and Increase Contrast's thicker outline.
private struct SizeKey: Equatable {
    let shape: String
    let label: String?
    let isPaused: Bool
    let hasProgress: Bool
    let style: TimerOverlayStyle
    let increaseContrast: Bool

    init(content: TimerOverlayContent, style: TimerOverlayStyle, increaseContrast: Bool) {
        shape = String(content.text.map { $0.isWholeNumber ? "0" : $0 })
        label = content.label
        isPaused = content.state == .paused
        hasProgress = content.progress != nil
        self.style = style
        self.increaseContrast = increaseContrast
    }
}

// MARK: - The panel's content

/// What the panel draws, changed only when what it shows changes. The panel's SwiftUI content is set once per pop-up
/// and reads this.
@MainActor @Observable
final class TimerOverlayModel {
    var content: TimerOverlayContent
    var style: TimerOverlayStyle
    var isPlacing: Bool
    /// The pop-in's and the pop-out's pose.
    var pose: TimerMotion.Pose
    /// A ring's pulse or flash.
    var beat: TimerMotion.Pose = .rest
    @ObservationIgnored var onDragChanged: @MainActor () -> Void = {}
    @ObservationIgnored var onDragEnded: @MainActor () -> Void = {}

    init(content: TimerOverlayContent, style: TimerOverlayStyle, isPlacing: Bool, pose: TimerMotion.Pose) {
        self.content = content
        self.style = style
        self.isPlacing = isPlacing
        self.pose = pose
    }
}

/// The panel's root: the overlay in the middle of the panel, moved as a whole by the pop and the beat. The digits
/// themselves never move (`TimerOverlayView` keeps its values still).
struct TimerOverlayPanelRoot: View {
    let model: TimerOverlayModel

    var body: some View {
        TimerOverlayView(content: model.content, style: model.style, isPlacing: model.isPlacing)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in model.onDragChanged() }
                .onEnded { _ in model.onDragEnded() })
            .allowsHitTesting(model.isPlacing)
            .scaleEffect(model.beat.scale)
            .opacity(model.beat.opacity)
            .scaleEffect(model.pose.scale)
            .offset(model.pose.offset)
            .opacity(model.pose.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Geometry

/// Where the panel and the plate go. Pure, in AppKit global points.
enum TimerOverlayGeometry {
    /// `frame` moved to whole points, so the plate's edges sit on the pixel grid; the size is kept.
    static func wholePoints(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width, height: frame.height)
    }

    /// The panel around a plate: the plate in the middle, with the motion margin on every side.
    static func panelFrame(plate: CGRect) -> CGRect {
        let margin = TimerMotion.margin(around: plate.size)
        return plate.insetBy(dx: -margin, dy: -margin)
    }

    /// `plate` at `size` around its center, on whole points. A plate that was on `display` stays on it (decision 2):
    /// moved back inside, or to its left or top edge when it's larger than the display.
    static func resized(_ plate: CGRect, to size: CGSize, within display: CGRect) -> CGRect {
        var frame = wholePoints(CGRect(x: plate.midX - size.width / 2, y: plate.midY - size.height / 2,
                                       width: size.width, height: size.height))
        guard display.contains(plate) else { return frame }
        frame.origin.x = size.width > display.width ? display.minX : min(max(frame.minX, display.minX), display.maxX - size.width)
        frame.origin.y = size.height > display.height ? display.maxY - size.height
            : min(max(frame.minY, display.minY), display.maxY - size.height)
        return frame
    }
}
