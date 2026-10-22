import STDesign
import SwiftUI

/// The overlay itself (spec 5.6.4): the time in the chosen font with tabular figures, on the look's plate, with the
/// optional small-caps label and a bar or ring that steps once a second. Paused adds a small-caps *Paused*; time's up
/// is drawn in the time's-up look. The page's preview plate draws this same view.
///
/// Nothing in it ever animates: a new text, color or progress is drawn at once in every mode, because a speedrunner
/// needs the new number now (spec 3.4). Only the presenter moves the whole plate. Its size comes out in whole points,
/// so its edges sit on the pixel grid.
///
/// It reads Increase Contrast from the `STTheme` in its environment: the app's theme on the page, and the one the
/// presenter puts there in the overlay's panel, never the fallback.
public struct TimerOverlayView: View {
    public let content: TimerOverlayContent
    let style: TimerOverlayStyle
    /// Placement mode: a dashed gold outline shows the plate can be dragged.
    var isPlacing: Bool
    @Environment(\.stTheme) private var theme

    public init(content: TimerOverlayContent, settings: TimerOverlaySettings) {
        self.init(content: content, style: TimerOverlayStyle(settings))
    }

    init(content: TimerOverlayContent, style: TimerOverlayStyle, isPlacing: Bool = false) {
        self.content = content
        self.style = style
        self.isPlacing = isPlacing
    }

    public var body: some View {
        let look = TimerLook(style: style, state: content.state, increaseContrast: theme.increaseContrast)
        let metrics = TimerOverlayMetrics(style: style, look: look, hasRing: ring != nil,
                                          isOneLine: caption == nil && bar == nil)
        PlateLayout(horizontal: metrics.horizontalPadding, vertical: metrics.verticalPadding,
                    corners: ring == nil ? look.plate?.shape : nil) {
            arrangement(look: look, metrics: metrics)
        }
        .background { plateFill(look) }
        .overlay { edges(look) }
        .fixedSize()
        // Values never animate (spec 3.4), whoever changes them inside an animation.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer Overlay")
        .accessibilityValue([caption, content.text].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: - The parts

    /// The small-caps line above the digits: the label, and *Paused* while paused. Placeholder wording for M9.
    private var caption: String? {
        let parts = [content.label, content.state == .paused ? "Paused" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private var bar: Double? { style.progress == .bar ? content.progress : nil }
    private var ring: Double? { style.progress == .ring ? content.progress : nil }

    @ViewBuilder
    private func arrangement(look: TimerLook, metrics: TimerOverlayMetrics) -> some View {
        if let ring {
            RingLayout(inset: metrics.ringGap + metrics.ringWidth) {
                block(look: look, metrics: metrics)
            }
            .overlay {
                TimerRing(fraction: ring, color: Color(hex: look.digitHex), lineWidth: metrics.ringWidth,
                          outline: look.outline?.colorHex)
            }
        } else {
            block(look: look, metrics: metrics)
        }
    }

    /// The caption over the digits, and the bar under them.
    private func block(look: TimerLook, metrics: TimerOverlayMetrics) -> some View {
        VStack(spacing: metrics.captionSpacing) {
            if let caption {
                OutlinedText(
                    text: caption, font: Font(TimerFont.caption(family: style.fontFamily, size: metrics.captionSize)),
                    color: Color(hex: look.captionHex), outline: look.outline.map { ($0.colorHex, metrics.captionOutline) },
                    tracking: metrics.captionTracking)
            }
            OutlinedText(
                text: content.text, font: Font(TimerFont.digits(family: style.fontFamily, size: metrics.digitSize)),
                color: Color(hex: look.digitHex), outline: look.outline.map { ($0.colorHex, $0.width) }, tracking: 0)
                .padding(.bottom, bar == nil ? 0 : metrics.barGap + metrics.barHeight)
                .overlay(alignment: .bottom) {
                    if let bar {
                        TimerBar(fraction: bar, color: Color(hex: look.digitHex), outline: look.outline?.colorHex)
                            .frame(height: metrics.barHeight)
                    }
                }
        }
    }

    @ViewBuilder
    private func plateFill(_ look: TimerLook) -> some View {
        if let plate = look.plate {
            PlateShape(shape: plate.shape).fill(Color(hex: plate.colorHex).opacity(plate.opacity))
        }
    }

    @ViewBuilder
    private func edges(_ look: TimerLook) -> some View {
        let shape = PlateShape(shape: look.plate?.shape ?? .rounded(Self.digitsOnlyCornerRadius))
        if content.showsDangerEdge {
            shape.strokeBorder(STColor.danger, lineWidth: look.dangerEdgeWidth)
        } else if isPlacing {
            shape.strokeBorder(STColor.gold, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else if let plate = look.plate, plate.edgeWidth > 0 {
            shape.strokeBorder(Color(hex: plate.edgeHex), lineWidth: plate.edgeWidth)
        }
    }

    /// The corners of the danger edge and the placement outline when there's no plate.
    static let digitsOnlyCornerRadius: CGFloat = 8
}

/// The overlay's measurements, from the digit size: every space grows with the digits.
struct TimerOverlayMetrics {
    let digitSize: CGFloat
    let captionSize: CGFloat
    let captionTracking: CGFloat
    let captionSpacing: CGFloat
    let captionOutline: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let barHeight: CGFloat
    let barGap: CGFloat
    let ringWidth: CGFloat
    let ringGap: CGFloat

    /// `isOneLine`: just the digits, with no caption above or bar below.
    init(style: TimerOverlayStyle, look: TimerLook, hasRing: Bool, isOneLine: Bool) {
        let size = CGFloat(style.digitSize)
        digitSize = size
        // Never under sTools' 12 pt minimum (spec 3.8).
        captionSize = max(12, (size * 0.3).rounded())
        captionTracking = captionSize * 0.04
        captionSpacing = (size * 0.04).rounded()
        let outline = look.outline?.width ?? 0
        captionOutline = outline > 0 ? max(1, outline * 0.6) : 0
        barHeight = max(2, size * 0.06)
        barGap = (size * 0.1).rounded()
        ringWidth = max(2, size * 0.07)
        ringGap = (size * 0.12).rounded()
        switch (style.look, hasRing) {
        case (.digitsOnly, _):
            horizontalPadding = (size * 0.12).rounded() + outline
            verticalPadding = horizontalPadding
        case (_, true):
            horizontalPadding = (size * 0.2).rounded()
            verticalPadding = horizontalPadding
        case (.compactPill, false):
            // Tighter than the plate around one line; a caption or a bar gets a little more room from the ends.
            horizontalPadding = (size * 0.5).rounded()
            verticalPadding = (size * (isOneLine ? 0.06 : 0.12)).rounded()
        case (.plate, false):
            horizontalPadding = (size * 0.4).rounded()
            verticalPadding = (size * 0.15).rounded()
        }
    }
}

// MARK: - Drawing pieces

/// Text with an optional dark outline around each glyph, drawn as copies of the text set off in every direction
/// behind it. The outline reaches past the text's frame by its width; the plate's padding leaves room for it.
private struct OutlinedText: View {
    let text: String
    let font: Font
    let color: Color
    let outline: (hex: String, width: CGFloat)?
    let tracking: CGFloat

    var body: some View {
        let label = Text(verbatim: text).font(font).tracking(tracking)
        label
            .foregroundStyle(color)
            .fixedSize()
            .background {
                if let outline, outline.width > 0 {
                    ZStack {
                        ForEach(Array(Self.offsets(width: outline.width).enumerated()), id: \.offset) { _, offset in
                            label.foregroundStyle(Color(hex: outline.hex)).fixedSize().offset(offset)
                        }
                    }
                }
            }
    }

    /// Points on a circle of `width` around the glyphs: 8 for a thin outline, 16 for a thick one, so no gap shows.
    static func offsets(width: CGFloat) -> [CGSize] {
        let count = width <= 1.5 ? 8 : 16
        return (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi
            return CGSize(width: width * cos(angle), height: width * sin(angle))
        }
    }
}

/// The plate's outline: rounded corners or round ends.
///
/// Round ends are circular, not continuous: a continuous capsule's stroke draws stray straight "ears" at its ends
/// in offscreen renders. A radius of half the height or more makes round ends too.
private struct PlateShape: InsettableShape {
    let shape: TimerLook.Shape
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: inset, dy: inset)
        switch shape {
        case .rounded(let radius) where radius < min(rect.width, rect.height) / 2:
            return RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous).path(in: inner)
        case .rounded, .capsule:
            return Capsule(style: .circular).path(in: inner)
        }
    }

    func inset(by amount: CGFloat) -> PlateShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// The bar under the digits: the time left from the leading edge, over a faint track. It steps once a second
/// because the content does; it never animates (no animatable data).
private struct TimerBar: View {
    let fraction: Double
    let color: Color
    let outline: String?

    var body: some View {
        ZStack {
            Capsule().fill(color.opacity(0.25))
            BarFill(fraction: fraction).fill(color)
        }
        .overlay {
            if let outline { Capsule().stroke(Color(hex: outline), lineWidth: 1) }
        }
    }
}

private struct BarFill: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let width = rect.width * fraction
        guard width > 0 else { return Path() }
        let filled = CGRect(x: rect.minX, y: rect.minY, width: max(width, rect.height), height: rect.height)
        return Capsule().path(in: filled)
    }
}

/// The ring around the digits: the time left clockwise from twelve o'clock, over a faint track.
private struct TimerRing: View {
    let fraction: Double
    let color: Color
    let lineWidth: CGFloat
    /// A dark line along both sides of the ring when there's no plate under it.
    let outline: String?

    var body: some View {
        ZStack {
            if let outline { Circle().stroke(Color(hex: outline), lineWidth: lineWidth + 2) }
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            RingArc(fraction: fraction).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .padding(lineWidth / 2 + (outline == nil ? 0 : 1))
    }
}

private struct RingArc: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        return path
    }
}

/// A square around its one subview, wide enough for a circle of `inset` around the subview's corners.
private struct RingLayout: Layout {
    let inset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        let side = (size.width * size.width + size.height * size.height).squareRoot() + 2 * inset
        return CGSize(width: side, height: side)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

/// The plate around its one subview: the padding, rounded up to whole points so the plate's edges sit on the pixel
/// grid, with the subview centered.
///
/// With `corners`, the sides are padded further when needed, until the subview's corners sit inside the plate's
/// rounded corners or round ends, so a bar under the digits never pokes out of a pill.
private struct PlateLayout: Layout {
    let horizontal: CGFloat
    let vertical: CGFloat
    let corners: TimerLook.Shape?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        let height = size.height + 2 * vertical
        return CGSize(width: (size.width + 2 * side(height: height)).rounded(.up), height: height.rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }

    /// The padding on each side: at least `horizontal`, and far enough in that the subview's top corner falls inside
    /// the corner's circle, which is centered `radius` in from the plate's corner.
    private func side(height: CGFloat) -> CGFloat {
        let radius: CGFloat = switch corners {
        case .rounded(let radius)?: min(radius, height / 2)
        case .capsule?: height / 2
        case nil: 0
        }
        guard radius > vertical else { return horizontal }
        let rise = radius - vertical
        return max(horizontal, radius - (radius * radius - rise * rise).squareRoot())
    }
}

// MARK: - What the overlay shows

/// What the overlay shows at one moment (plan, "Interfaces between tasks"). The controller builds one for each shown
/// change and hands it to the presenter; the page's preview plate draws the same value.
public struct TimerOverlayContent: Equatable, Sendable {
    /// Which colors the time is drawn in (spec 5.6.4). The words and digits always say the same thing, so color is
    /// never the only signal (spec 3.3).
    public enum State: String, Sendable, CaseIterable {
        case counting
        /// `gold` digits from "Color near zero"'s first time.
        case nearZeroGold
        /// `danger` digits from its second time.
        case nearZeroDanger
        /// Dimmed digits, marked *Paused*.
        case paused
        /// The time's-up look, from zero until the overlay leaves.
        case timesUp
    }

    /// The time as written: `02:30`, `00:09.9`, the word at zero, or overtime such as `+0:07`.
    public var text: String
    public var state: State
    /// The time left as a fraction of the run, 1 → 0, stepped with the shown seconds; nil draws no bar or ring.
    public var progress: Double? {
        didSet { progress = Self.sanitized(progress) }
    }
    /// The small-caps label, or nil for none.
    public var label: String?
    /// Whether the plate's edge turns `danger`, while it's dragged over an area the speedrun rules need visible
    /// (spec 5.6.5).
    public var showsDangerEdge: Bool

    public init(text: String, state: State = .counting, progress: Double? = nil, label: String? = nil,
                showsDangerEdge: Bool = false) {
        self.text = text
        self.state = state
        self.progress = Self.sanitized(progress)
        self.label = label
        self.showsDangerEdge = showsDangerEdge
    }

    /// The content `settings` ask for: their label when it's on, and `steppedProgress` (as from
    /// `Countdown.steppedProgress`) when they show a bar or a ring.
    public init(text: String, state: State, steppedProgress: Double, settings: TimerOverlaySettings,
                showsDangerEdge: Bool = false) {
        let label = settings.labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(text: text, state: state, progress: settings.progress == .off ? nil : steppedProgress,
                  label: settings.showsLabel && !label.isEmpty ? label : nil, showsDangerEdge: showsDangerEdge)
    }

    /// The state while counting with `shownSeconds` on the overlay: `gold`, then `danger`, from the times "Color near
    /// zero" sets (spec 5.6.4, Timer round C3), and plain counting otherwise.
    public static func countingState(shownSeconds: Int, settings: TimerOverlaySettings) -> State {
        switch settings.nearZero {
        case .off:
            return .counting
        case .gold:
            return shownSeconds <= settings.nearZeroGoldSeconds ? .nearZeroGold : .counting
        case .goldThenDanger:
            if shownSeconds <= settings.nearZeroDangerSeconds { return .nearZeroDanger }
            return shownSeconds <= settings.nearZeroGoldSeconds ? .nearZeroGold : .counting
        }
    }

    private static func sanitized(_ progress: Double?) -> Double? {
        progress.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
    }
}
