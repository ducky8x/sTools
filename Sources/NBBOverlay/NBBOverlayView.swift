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

    var body: some View {
        STPlate(tint: plateTint) {
            plateContent
                .padding(14)
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
                NBBFailedBlock(eyeThrows: eyeThrows)
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

// MARK: - Shared text styles (New York, per spec 5.1.3)

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
                NBBHeading(text: "Predictions")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(data.predictions.enumerated()), id: \.element.id) { index, row in
                        NBBPredictionRowView(row: row, isTop: index == 0, settings: settings)
                    }
                }
            }
            if settings.showsEyeThrows, !data.eyeThrows.isEmpty {
                NBBHeading(text: "Eye throws")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(data.eyeThrows.enumerated()), id: \.offset) { _, eyeThrow in
                        HStack(spacing: 10) {
                            Text("\(Int(eyeThrow.xInOverworld)), \(Int(eyeThrow.zInOverworld))").font(nbbNumber())
                            Text("\(eyeThrow.angle, specifier: "%.1f")°").font(nbbNumber())
                            Text("±\(eyeThrow.error, specifier: "%.3f")").font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
                        }
                        .foregroundStyle(STColor.ink)
                    }
                }
            }
        }
    }
}

private struct NBBPredictionRowView: View {
    let row: PredictionRow
    let isTop: Bool
    let settings: NBBOverlaySettings

    var body: some View {
        HStack(spacing: 12) {
            if settings.showsLocationColumn {
                Text("\(row.chunkX), \(row.chunkZ)").font(nbbNumber(weight: isTop ? .semibold : .regular))
            }
            if settings.showsCertaintyColumn {
                Text("\(row.certaintyPercent)%")
                    .font(nbbNumber(weight: isTop ? .semibold : .regular))
                    .foregroundStyle(isTop ? STColor.gold : STColor.ink)
            }
            if settings.showsDistanceColumn {
                Text("\(Int(row.overworldDistance))m").font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
            }
        }
        .foregroundStyle(STColor.ink)
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

// MARK: - Failed

struct NBBFailedBlock: View {
    let eyeThrows: [NBBEvents.EyeThrow]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Triangulation failed").font(nbbLabel(13)).foregroundStyle(STColor.danger)
            ForEach(Array(eyeThrows.enumerated()), id: \.offset) { _, eyeThrow in
                Text("\(Int(eyeThrow.xInOverworld)), \(Int(eyeThrow.zInOverworld)) — \(eyeThrow.angle, specifier: "%.1f")°")
                    .font(nbbNumber())
                    .foregroundStyle(STColor.inkSecondary)
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
            Text("High-roll: \(Int((result.highrollProbability * 100).rounded()))% within \(Int(result.highrollThreshold))m")
                .font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
            // Raw improve direction/distance, not Ninjabrain Bot's own worded hint — see
            // NBBOverlaySettings' doc comment on why this build doesn't phrase it the way NBB does.
            Text("Improve: \(Int(result.improveDistance))m at \(Int(result.improveDirection * 180 / .pi))°")
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
            ("Outpost", data.outpost), ("Deep Dark", data.deepDark), ("City query", data.cityQuery),
            ("Shulker transport", data.shulkerTransport), ("General", data.generalLocation),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NBBHeading(text: "All advancements")
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { name, position in
                if let position {
                    HStack(spacing: 10) {
                        Text(name).font(nbbLabel()).foregroundStyle(STColor.inkSecondary).frame(width: 110, alignment: .leading)
                        Text("\(Int(position.xInOverworld)), \(Int(position.zInOverworld))").font(nbbNumber())
                        Text("\(Int(position.overworldDistance))m").font(nbbNumber()).foregroundStyle(STColor.inkSecondary)
                    }
                    .foregroundStyle(STColor.ink)
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
