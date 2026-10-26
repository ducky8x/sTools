import STDesign
import SwiftUI

/// The floating overlay itself (spec 5.1.3): "New York with monospaced digits, ink on the dark
/// plate; the top prediction's certainty in gold." Uses the system serif directly (not `STFont`,
/// which now carries the app's own chrome typography) since the spec names this font specifically
/// for this one component, drawn over the game rather than inside sTools' own window.
struct NBBOverlayView: View {
    let content: NBBOverlayContent
    let messages: [(severity: NBBEvents.MessageSeverity, text: String)]
    let settings: NBBOverlaySettings
    /// Ninjabrain Bot's latest boat state, for the boat indicator and the plate's color.
    var boat: NBBEvents.Boat?

    /// Placement mode (spec 5.1.5): drag the body to move, drag the corner handle to resize. Each
    /// `changed` callback receives the gesture's cumulative translation from where it started; `ended`
    /// commits. No-ops when placement mode is off (the view doesn't take hit-testing then anyway).
    var onMoveChanged: (CGSize) -> Void = { _ in }
    var onMoveEnded: () -> Void = {}
    var onResizeChanged: (CGSize) -> Void = { _ in }
    var onResizeEnded: () -> Void = {}

    /// The width setting's own baseline — matches the plate's original fixed width, so `width == 320`
    /// (the default) renders text at its natural, un-scaled size.
    private static let baseWidth: CGFloat = 320

    private var shownBoat: NBBEvents.BoatState? { NBBOverlayLayout.boatToShow(boat, settings: settings) }
    private var isEmpty: Bool { content == .hidden && messages.isEmpty && !NBBOverlayLayout.boatCountsAsData(boat, settings: settings) }
    private var plateTint: Color? { NBBOverlayLayout.plateTint(boat, settings: settings).map { STColorWellHex.color(from: $0.colorHex) } }
    private var targetSize: CGSize { CGSize(width: CGFloat(settings.width), height: CGFloat(settings.width) / settings.aspectRatio) }

    /// A plain `width / baseWidth` ratio, not a measure-then-fit scale: resizing the box (by the Width
    /// setting or by dragging the handle) grows or shrinks the data directly and immediately. The
    /// earlier measure-and-fit approach recomputed from a `@State` that reset to zero every time
    /// settings changed — which is continuously, while dragging a slider or the resize handle — so the
    /// content visibly stayed at its unscaled size in the corner instead of resizing live.
    private var contentScale: CGFloat { CGFloat(settings.width) / Self.baseWidth }

    /// The room inside the plate's padding, before `contentScale`: what the content has to fit in.
    private var available: CGSize {
        CGSize(width: targetSize.width / contentScale - 2 * Self.padding, height: targetSize.height / contentScale - 2 * Self.padding)
    }

    private static let padding: CGFloat = 14

    var body: some View {
        STPlate(tint: plateTint) {
            plateContent
                .modifier(NBBPlateFit(available: available))
                .padding(Self.padding)
                .scaleEffect(contentScale, anchor: .topLeading)
                .frame(width: targetSize.width, height: targetSize.height, alignment: .topLeading)
                .clipped()
        }
        .overlay {
            if settings.placementModeEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(STColor.gold, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if settings.placementModeEnabled {
                NBBResizeHandle()
                    .gesture(DragGesture(minimumDistance: 0).onChanged { onResizeChanged($0.translation) }.onEnded { _ in onResizeEnded() })
            }
        }
        .frame(width: targetSize.width, height: targetSize.height)
        .opacity(isEmpty && !settings.placementModeEnabled ? 0 : Double(settings.plateOpacityPercent) / 100)
        .contentShape(Rectangle())
        // Gated by `allowsHitTesting` below rather than a conditional gesture, so this stays one
        // concrete gesture type regardless of placement mode.
        .gesture(DragGesture(minimumDistance: 0).onChanged { onMoveChanged($0.translation) }.onEnded { _ in onMoveEnded() })
        .allowsHitTesting(settings.placementModeEnabled)
    }

    @ViewBuilder private var plateContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shownBoat {
                NBBBoatIndicator(look: NBBBoatLook(shownBoat))
            }
            switch content {
            case .hidden:
                if settings.placementModeEnabled, shownBoat == nil {
                    Text("NBB Overlay").stStyle(.caption).foregroundStyle(STColor.inkTertiary)
                }
            case .triangulation(let data):
                NBBTriangulationBlock(data: data, settings: settings)
            case .failed(let eyeThrows):
                NBBFailedBlock(eyeThrows: eyeThrows, settings: settings)
            case .blind(let result):
                NBBBlindBlock(result: result)
            case .divine(let result):
                NBBDivineBlock(result: result)
            case .allAdvancements(let data):
                NBBAllAdvancementsBlock(data: data)
            }
            if !messages.isEmpty {
                NBBMessagesBlock(messages: messages)
            }
        }
    }
}

// MARK: - Fitting the plate

/// Fits the plate's content inside the plate (spec 5.1.3): laid out at its natural size for the plate's width (the
/// numbers' rows never wrap or truncate, messages wrap), then, when that's taller or wider than the room inside the
/// padding, scaled down uniformly from the top-leading corner until it fits, never below `minimumScale`; past that the
/// plate clips it as before. Nothing is ever scaled up.
///
/// The scale comes from the content's own laid-out size in `visualEffect`, at draw time in the same pass: no state, no
/// second layout, so a pushed result is drawn fitted in the turn it arrives, and a scale never changes the size it was
/// worked out from (a scale effect leaves layout alone), so it can't loop.
struct NBBPlateFit: ViewModifier {
    /// The room the content has, in its own points.
    let available: CGSize

    /// The smallest the content is drawn: the 12 pt numbers at about 7 pt, as small as stays readable over the game.
    nonisolated static let minimumScale: CGFloat = 0.6

    /// How much content of `natural` size is scaled to fit `available`: 1 when it fits, else the tighter of the two
    /// ratios, never under `minimumScale`.
    nonisolated static func scale(natural: CGSize, available: CGSize) -> CGFloat {
        guard natural.width > 0, natural.height > 0 else { return 1 }
        let fit = min(1, max(0, available.width) / natural.width, max(0, available.height) / natural.height)
        return max(minimumScale, fit)
    }

    func body(content: Content) -> some View {
        let available = available
        NBBNaturalSize(width: available.width) { content }
            .visualEffect { view, geometry in
                view.scaleEffect(Self.scale(natural: geometry.size, available: available), anchor: .topLeading)
            }
    }
}

/// Lays its one view out at the given width and its own ideal height, and takes the size it comes to, wider than the
/// width included: a frame would report the width it was given and hide what spills over.
struct NBBNaturalSize: Layout {
    let width: CGFloat

    private var proposal: ProposedViewSize { ProposedViewSize(width: max(0, width), height: nil) }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

// MARK: - Shared text styles (New York, per spec 5.1.3)

// Numbers go in `Text(verbatim:)`: a localized `Text` writes an interpolated Int with the Mac's grouping separator
// ("-1,374"), which Ninjabrain Bot never shows.

private func nbbLabel(_ size: CGFloat = 12) -> Font { .system(size: size, design: .serif) }
private func nbbNumber(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .serif).monospacedDigit()
}

private struct NBBHeading: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(nbbLabel(11))
            .tracking(1)
            .foregroundStyle(STColor.inkSecondary)
    }
}

// MARK: - Triangulation

struct NBBTriangulationBlock: View {
    let data: TriangulationContent
    let settings: NBBOverlaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.showsPredictions, !data.predictions.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    NBBHeading(text: "Predictions")
                    // Says whose coordinates and distance the table shows, whenever either column is on.
                    if settings.showsLocationColumn || settings.showsDistanceColumn {
                        NBBColumnMark(column: data.column)
                    }
                }
                // A grid, so each column lines up from row to row.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(data.predictions.enumerated()), id: \.element.id) { index, row in
                        NBBPredictionRowView(row: row, isTop: index == 0, settings: settings)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if settings.showsEyeThrows, !data.eyeThrows.isEmpty {
                NBBHeading(text: "Eye throws")
                // A grid too, so the errors line up whether or not a throw's angle was adjusted.
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(Array(data.eyeThrows.enumerated()), id: \.offset) { _, eyeThrow in
                        GridRow {
                            Text(verbatim: "\(Int(eyeThrow.xInOverworld)), \(Int(eyeThrow.zInOverworld))").font(nbbNumber())
                            NBBThrowAngle(eyeThrow: eyeThrow, settings: settings)
                            if let error = NBBThrowError.text(eyeThrow) {
                                Text(verbatim: error).font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
                            }
                        }
                        .foregroundStyle(STColor.ink)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

private struct NBBPredictionRowView: View {
    let row: PredictionRow
    let isTop: Bool
    let settings: NBBOverlaySettings

    var body: some View {
        GridRow {
            if settings.showsLocationColumn {
                Text(row.coordinates.text).font(nbbNumber(weight: isTop ? .semibold : .regular))
            }
            if settings.showsCertaintyColumn {
                Text(verbatim: "\(row.certaintyPercent)%")
                    .font(nbbNumber(weight: isTop ? .semibold : .regular))
                    .foregroundStyle(isTop ? STColor.gold : STColor.ink)
            }
            if settings.showsDistanceColumn {
                // Verbatim, so the number reads as Ninjabrain Bot writes it ("1579", no grouping separator).
                Text(verbatim: "\(row.distance)m").font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
            }
            if settings.showsAngleColumn, let angle = row.angle {
                Text(String(format: "%.2f\u{00B0}", angle)).font(nbbNumber())
            }
            if settings.showsAngleChangeColumn, let change = row.angleChange {
                Text(NBBAngleChange.text(change))
                    .font(nbbNumber())
                    .foregroundStyle(NBBAngleChange.color(change))
                    .accessibilityLabel(NBBAngleChange.spoken(change))
            }
        }
        .foregroundStyle(STColor.ink)
    }
}

/// A small tag beside the Predictions heading: Overworld, Nether, or (from a window, which doesn't say) Location, in the
/// heading's own letters, tinted faintly green for the Overworld and red for the Nether.
struct NBBColumnMark: View {
    let column: NBBCoordinateColumn

    static func colorHex(_ column: NBBCoordinateColumn) -> String? {
        switch column {
        case .overworld: "#6FCB7A"
        case .nether: "#E8695C"
        case .windowLocation: nil
        }
    }

    private var color: Color { Self.colorHex(column).map { STColorWellHex.color(from: $0) } ?? STColor.inkSecondary }

    var body: some View {
        Text(column.title.uppercased())
            .font(nbbLabel(9))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.75))
            .accessibilityLabel(column.spoken)
    }
}

// MARK: - Boat

/// Ninjabrain Bot's boat, as large as a heading: a boat drawn in the state's color, then what it means.
struct NBBBoatIndicator: View {
    let look: NBBBoatLook

    var body: some View {
        HStack(spacing: 8) {
            NBBBoatGlyph()
                .fill(STColorWellHex.color(from: look.colorHex))
                .frame(width: 26, height: 14)
            Text(look.title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(STColor.ink)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.title)
    }
}

/// A boat seen from the side: a hull wider at the top, with a gunwale along it.
struct NBBBoatGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        // Gunwale.
        path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h * 0.22), cornerSize: CGSize(width: h * 0.08, height: h * 0.08))
        // Hull.
        path.move(to: CGPoint(x: x + w * 0.03, y: y + h * 0.34))
        path.addLine(to: CGPoint(x: x + w * 0.97, y: y + h * 0.34))
        path.addLine(to: CGPoint(x: x + w * 0.80, y: y + h))
        path.addLine(to: CGPoint(x: x + w * 0.20, y: y + h))
        path.closeSubpath()
        return path
    }
}

/// The turn to the travel angle as the overlay writes it: an arrow the way to turn and how far, to a tenth of a degree,
/// as Ninjabrain Bot's " (-> 47.4)"; it goes from red when the stronghold is behind to green when it's ahead, as
/// Ninjabrain Bot shades it.
enum NBBAngleChange {
    static func text(_ change: Double) -> String {
        String(format: "%@ %.1f", change > 0 ? "\u{2192}" : "\u{2190}", abs(change))
    }

    static func spoken(_ change: Double) -> String {
        String(format: "Turn %@ %.1f degrees", change > 0 ? "right" : "left", abs(change))
    }

    /// 1 when facing the stronghold, 0 when it's straight behind.
    static func closeness(_ change: Double) -> Double { 1 - min(abs(change), 180) / 180 }

    static func color(_ change: Double) -> Color {
        STColor.danger.mix(with: STColor.success, by: closeness(change))
    }
}

// MARK: - Failed

struct NBBFailedBlock: View {
    let eyeThrows: [NBBEvents.EyeThrow]
    let settings: NBBOverlaySettings
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Triangulation failed").font(nbbLabel(13)).foregroundStyle(STColor.danger)
            ForEach(Array(eyeThrows.enumerated()), id: \.offset) { _, eyeThrow in
                HStack(spacing: 0) {
                    Text(verbatim: "\(Int(eyeThrow.xInOverworld)), \(Int(eyeThrow.zInOverworld)) — ").font(nbbNumber())
                    NBBThrowAngle(eyeThrow: eyeThrow, settings: settings)
                }
                .foregroundStyle(STColor.inkSecondary)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// A throw's angle as Ninjabrain Bot shows it: before the correction, to two decimals, then the correction beside it in
/// green (up) or red (down), and nothing there when the angle wasn't adjusted (`NBBAngleCorrection`).
struct NBBThrowAngle: View {
    let eyeThrow: NBBEvents.EyeThrow
    let settings: NBBOverlaySettings

    private var correction: String? {
        settings.showsAngleCorrection ? NBBAngleCorrection.text(eyeThrow, display: settings.correctionDisplay) : nil
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: NBBAngleCorrection.angleText(eyeThrow) + "\u{00B0}").font(nbbNumber())
            if let correction {
                Text(verbatim: correction)
                    .font(nbbNumber())
                    .foregroundStyle(STColorWellHex.color(from: NBBAngleCorrection.colorHex(correction)))
                    .accessibilityLabel("Adjusted \(correction)")
            }
        }
    }
}

// MARK: - Blind

struct NBBBlindBlock: View {
    let result: NBBEvents.BlindResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NBBHeading(text: "Blind travel")
            Text(result.evaluation).font(nbbLabel(13)).foregroundStyle(STColor.ink)
            Text(verbatim: "High-roll: \(Int((result.highrollProbability * 100).rounded()))% within \(Int(result.highrollThreshold))m")
                .font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
            // Raw improve direction/distance, not Ninjabrain Bot's own worded hint — see
            // NBBOverlaySettings' doc comment on why this build doesn't phrase it the way NBB does.
            Text(verbatim: "Improve: \(Int(result.improveDistance))m at \(Int(result.improveDirection * 180 / .pi))°")
                .font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
        }
    }
}

// MARK: - Divine

struct NBBDivineBlock: View {
    let result: NBBEvents.DivineResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NBBHeading(text: "Divine travel")
            Text("Safe: \(result.formattedSafeCoords)").font(nbbNumber()).foregroundStyle(STColor.ink)
            Text("High-roll: \(result.formattedHighrollCoords)").font(nbbNumber()).foregroundStyle(STColor.gold)
        }
    }
}

// MARK: - All advancements

struct NBBAllAdvancementsBlock: View {
    let data: NBBEvents.AllAdvancements
    private var rows: [(String, NBBEvents.Position?)] {
        [
            ("Spawn", data.spawn), ("Monument", data.monument), ("Stronghold", data.stronghold),
            ("Outpost", data.outpost), ("Deep Dark", data.deepDark), ("City Query", data.cityQuery),
            ("Shulker Transport", data.shulkerTransport), ("General", data.generalLocation),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NBBHeading(text: "All advancements")
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { name, position in
                if let position {
                    HStack(spacing: 10) {
                        Text(name).font(nbbLabel()).foregroundStyle(STColor.inkSecondary).frame(width: 110, alignment: .leading)
                        Text(verbatim: "\(Int(position.xInOverworld)), \(Int(position.zInOverworld))").font(nbbNumber())
                        Text(verbatim: "\(Int(position.overworldDistance))m").font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
                    }
                    .foregroundStyle(STColor.ink)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

// MARK: - Information messages

struct NBBMessagesBlock: View {
    let messages: [(severity: NBBEvents.MessageSeverity, text: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                Text(message.text)
                    .font(nbbLabel(11))
                    .foregroundStyle(color(for: message.severity))
            }
        }
    }

    private func color(for severity: NBBEvents.MessageSeverity) -> Color {
        switch severity {
        case .info: STColor.inkSecondary
        case .warning: STColor.gold
        case .error: STColor.danger
        }
    }
}

// MARK: - Placement mode

/// The bottom-right drag-to-resize affordance (spec 5.1.5 placement mode).
private struct NBBResizeHandle: View {
    var body: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(STColor.background)
            .padding(5)
            .background(STColor.gold, in: Circle())
            .padding(6)
            .contentShape(Rectangle())
    }
}
