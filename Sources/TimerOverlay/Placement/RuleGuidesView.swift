import AppKit
import Observation
import STDesign
import STPlatform
import SwiftUI

// MARK: - Presenting

/// The rule guides while the plate is dragged (spec 5.6.5, Timer round I2): the rule zones outlined over the
/// display, the ones the plate covers in `danger`, and one line under the plate naming them. Advisory only: it
/// never stops a placement. The plate draws its own `danger` edge from its content.
///
/// A protocol so the controller's tests can watch the guides without a window.
@MainActor
public protocol RuleGuidesPresenting: AnyObject {
    /// Outlines `zones` over `display`, under the plate. Called as a drag starts; guides still up from another drag
    /// are replaced.
    func show(_ zones: RuleZones, on display: DisplayInfo)
    /// Marks the zones the plate covers in `danger` and names them in one line under the plate, which sits at
    /// `plateFrame` (AppKit global points). Called on each move of the drag; a move that changes neither does nothing.
    func markCovered(_ kinds: [RuleZones.Kind], plateFrame: CGRect)
    /// Takes the guides away and releases their window at once. Called as the drag ends.
    func hide()
}

/// The live guides: a click-through panel over the whole display that exists only from a drag's start to its end.
///
/// The panel is excluded from capture: the guides help place the plate and are never part of a recording. It sits
/// one level below the overlays, so it's always under the plate (and the other overlays) whatever order they were
/// shown in, and above Minecraft, the menu bar and the Dock.
///
/// Motion (spec 3.4): the guides fade in with `STMotion.quick`, and appear at once while motion is reduced. They
/// leave at once in both modes, because their window must not outlive the drag. Marking covered zones never
/// animates. The panel's root gets `stMotionRoot` with the app's theme, which an overlay panel's own SwiftUI root
/// wouldn't otherwise see.
@MainActor
public final class RuleGuidesPresenter: RuleGuidesPresenting {
    /// One below the overlays' level (`OverlayPanel`'s topmost role).
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    private let theme: STTheme
    /// The guides' window while a drag is on. Internal so tests can read it.
    private(set) var panel: OverlayPanel?
    /// What the guides draw while a drag is on. Internal so tests can read it.
    private(set) var model: RuleGuidesModel?
    /// How many times the guides' view was built: once per drag. For tests.
    private(set) var buildCount = 0

    public init(theme: STTheme) {
        self.theme = theme
    }

    public func show(_ zones: RuleZones, on display: DisplayInfo) {
        hide()
        let model = RuleGuidesModel(zones: zones, display: display.frame)
        let panel = OverlayPanel(role: .topmost, isExcludedFromCapture: true)
        panel.level = Self.level
        // Read as the guides appear, so a change of the setting applies to the next drag.
        panel.setContent(RuleGuidesView(model: model, startsShown: theme.reduceMotion)
            .stMotionRoot(theme)
            .environment(\.stTheme, theme))
        panel.show(frame: display.frame)
        self.panel = panel
        self.model = model
        buildCount += 1
    }

    public func markCovered(_ kinds: [RuleZones.Kind], plateFrame: CGRect) {
        model?.mark(kinds, plateFrame: plateFrame)
    }

    public func hide() {
        guard let panel else { return }
        panel.hide()
        // The view tree goes with the window.
        panel.contentView = nil
        self.panel = nil
        model = nil
    }
}

// MARK: - What the guides draw

/// The zones over one display, which of them the plate covers, and where the plate is while it covers any.
@MainActor
@Observable
final class RuleGuidesModel {
    /// The zones' rectangles in the panel's own coordinates: points from the display's top-left corner, y down.
    let outlines: [Outline]
    /// The display the panel covers, AppKit global points.
    let display: CGRect
    private(set) var covered: [RuleZones.Kind] = []
    /// The plate in the panel's coordinates while it covers a zone, for the line under it. Nil otherwise, so moves
    /// over open ground redraw nothing.
    private(set) var plate: CGRect?
    /// How many times what the guides draw changed. For tests.
    @ObservationIgnored private(set) var changeCount = 0

    struct Outline: Equatable {
        let kind: RuleZones.Kind
        let rect: CGRect
    }

    init(zones: RuleZones, display: CGRect) {
        self.display = display
        outlines = zones.zones.flatMap { zone in
            zone.rects.map { Outline(kind: zone.kind, rect: Self.local($0, in: display)) }
        }
    }

    var line: String? { RuleZones.coverLine(for: covered) }

    func mark(_ kinds: [RuleZones.Kind], plateFrame: CGRect) {
        if kinds != covered {
            covered = kinds
            changeCount += 1
        }
        let plate = kinds.isEmpty ? nil : Self.local(plateFrame, in: display)
        if plate != self.plate {
            self.plate = plate
            changeCount += 1
        }
    }

    /// An AppKit global rectangle in the coordinates of a view covering `display`.
    static func local(_ rect: CGRect, in display: CGRect) -> CGRect {
        CGRect(x: rect.minX - display.minX, y: display.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The guides over the whole display: each zone's outline, dashed in `ink` or solid in `danger` while covered, and
/// the line under the plate.
struct RuleGuidesView: View {
    let model: RuleGuidesModel
    @State private var isShown: Bool
    @Environment(\.stTheme) private var theme

    /// `startsShown`: already on screen in full, with no fade, for reduced motion.
    init(model: RuleGuidesModel, startsShown: Bool) {
        self.model = model
        _isShown = State(initialValue: startsShown)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Its own view, so the line following the plate never redraws the whole display.
            ZoneOutlines(outlines: model.outlines, covered: model.covered, isHighContrast: theme.increaseContrast)
                .equatable()
            if let line = model.line, let plate = model.plate {
                LineLayout(plate: plate) { CoverLine(text: line) }
            }
        }
        // Covering a zone shows at once, in both modes: no animation reaches the outlines or the line.
        .transaction { $0.animation = nil }
        .frame(width: model.display.width, height: model.display.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .opacity(isShown ? 1 : 0)
        .onAppear {
            guard !isShown else { return }
            STMotion.animate(STMotion.quick, reduce: theme.reduceMotion) { isShown = true }
        }
    }

    /// Places its one view beside the plate, at its own size, where `origin(of:beside:in:)` says.
    struct LineLayout: Layout {
        /// Room between the plate, the line and the display's edges.
        static let gap: CGFloat = 8

        let plate: CGRect

        /// Where a line of `size` goes, in the coordinates of a view of `bounds` (y down): centered under the plate,
        /// or above it when there's no room below, and kept inside the display. Whole points, so the text stays crisp.
        static func origin(of size: CGSize, beside plate: CGRect, in bounds: CGSize) -> CGPoint {
            let x = min(max(plate.midX - size.width / 2, gap), max(gap, bounds.width - size.width - gap))
            var y = plate.maxY + gap
            if y + size.height > bounds.height - gap { y = max(gap, plate.minY - gap - size.height) }
            return CGPoint(x: x.rounded(), y: y.rounded())
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions()
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let line = subviews.first else { return }
            let size = line.sizeThatFits(.unspecified)
            let origin = Self.origin(of: size, beside: plate, in: bounds.size)
            line.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(size))
        }
    }
}

/// Every zone's outline in one drawing, redrawn only when what's covered (or Increase Contrast) changes.
private struct ZoneOutlines: View, Equatable {
    let outlines: [RuleGuidesModel.Outline]
    let covered: [RuleZones.Kind]
    let isHighContrast: Bool

    var body: some View {
        Canvas { context, _ in
            for outline in outlines {
                draw(outline, covered: covered.contains(outline.kind), in: &context)
            }
        }
    }

    private func draw(_ outline: RuleGuidesModel.Outline, covered: Bool, in context: inout GraphicsContext) {
        let width: CGFloat = isHighContrast ? 2.5 : 1.5
        let path = Path(outline.rect.insetBy(dx: width / 2, dy: width / 2))
        if covered { context.fill(path, with: .color(STColor.danger.opacity(0.18))) }
        // A dark halo under the line keeps it readable over sky and snow.
        context.stroke(path, with: .color(STColor.background.opacity(0.6)), lineWidth: width + 2)
        let style = StrokeStyle(lineWidth: width, dash: covered || isHighContrast ? [] : [6, 4])
        context.stroke(path, with: .color(covered ? STColor.danger : STColor.ink.opacity(0.9)), style: style)
    }
}

/// The one line naming what the plate covers, on a small dark plate so it reads over the game.
private struct CoverLine: View {
    let text: String

    var body: some View {
        Text(text)
            .stStyle(.body)
            .foregroundStyle(STColor.danger)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(STColor.background.opacity(0.85), in: Capsule())
            .overlay { Capsule().strokeBorder(STColor.danger.opacity(0.6), lineWidth: 1) }
    }
}
