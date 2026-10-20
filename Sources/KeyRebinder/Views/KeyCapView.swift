import STDesign
import SwiftUI

/// What one key shows besides its legend.
struct KeyCapState: Equatable {
    /// The new output, drawn in gold beneath the legend; nil when the key is not rebound.
    var output: String?
    /// Minecraft's action for what the key now sends, in small caps.
    var action: String?
    /// Driven by a rule the plate can't draw as "this key sends that key" (spec 5.5.2).
    var isRuleDriven = false
    var isFlagged = false
    var isSelected = false
    /// The key an event just arrived as, while testing.
    var isLit = false
    /// A physical key that produces the lit event.
    var isSource = false
}

/// One key or mouse button, drawn from its frames in board points.
struct KeyCapView: View {
    let legend: String
    let parts: [CGRect]
    let state: KeyCapState
    let unit: CGFloat

    @Environment(\.stTheme) private var theme

    private var bounds: CGRect { parts.dropFirst().reduce(parts[0]) { $0.union($1) } }

    var body: some View {
        let shape = KeyShape(parts: parts.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }, inset: unit * 0.05, radius: unit * 0.12)
        ZStack(alignment: .topLeading) {
            shape.fill(state.isLit ? theme.accent.opacity(0.32) : STColor.raised)
            shape.stroke(strokeColor, style: StrokeStyle(lineWidth: strokeWidth, dash: state.isSource && !state.isLit ? [3, 2] : []))
            labels
                .padding(.horizontal, unit * 0.12)
                .padding(.vertical, unit * 0.08)
                .frame(width: (parts.first?.width ?? 0), height: (parts.first?.height ?? 0), alignment: .topLeading)
                .clipped()
            marks
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    private var strokeColor: Color {
        if state.isSelected || state.isLit || state.isSource { return theme.accent }
        return theme.stroke.opacity(0.7)
    }

    private var strokeWidth: CGFloat {
        state.isSelected ? 2 : (state.isLit || state.isSource ? 1.5 : 1)
    }

    @ViewBuilder private var labels: some View {
        let height = parts.first?.height ?? unit
        VStack(alignment: .leading, spacing: 0) {
            Text(legend)
                .font(STFont.text(unit * 0.25))
                .foregroundStyle(state.output == nil ? STColor.ink : theme.inkSecondary)
            if height >= unit * 0.6 {
                Spacer(minLength: 0)
                if let output = state.output {
                    Text(output)
                        .font(STFont.text(unit * 0.25, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                if let action = state.action, height >= unit * 0.9 {
                    Text(action)
                        .font(STFont.label(scale: Double(unit * 0.19 / 12)))
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    /// Badges on the key's top-right corner, clear of the legend.
    @ViewBuilder private var marks: some View {
        HStack(spacing: unit * 0.04) {
            if state.isRuleDriven {
                Text("\u{25C6}").font(.system(size: unit * 0.18)).foregroundStyle(theme.accent)
            }
            if state.isFlagged {
                Circle().fill(STColor.danger).frame(width: unit * 0.14, height: unit * 0.14)
            }
        }
        .padding(.horizontal, unit * 0.05)
        .background(STColor.surface, in: Capsule())
        .opacity(state.isRuleDriven || state.isFlagged ? 1 : 0)
        .offset(x: unit * 0.06, y: -unit * 0.1)
        .frame(width: parts.first?.width ?? 0, alignment: .topTrailing)
        .accessibilityHidden(true)
    }
}

/// A key's outline: a rounded rect, or the L of an ISO/JIS Return (a wider top part over a narrower bottom
/// part, right edges aligned).
struct KeyShape: Shape {
    let parts: [CGRect]
    let inset: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard parts.count == 2 else {
            return Path(roundedRect: parts[0].insetBy(dx: inset, dy: inset), cornerRadius: radius)
        }
        let top = parts[0], bottom = parts[1], g = inset
        let corners = [
            CGPoint(x: top.minX + g, y: top.minY + g), CGPoint(x: top.maxX - g, y: top.minY + g),
            CGPoint(x: bottom.maxX - g, y: bottom.maxY - g), CGPoint(x: bottom.minX + g, y: bottom.maxY - g),
            CGPoint(x: bottom.minX + g, y: top.maxY - g), CGPoint(x: top.minX + g, y: top.maxY - g),
        ]
        var path = Path()
        let last = corners[corners.count - 1]
        path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
        for index in corners.indices {
            path.addArc(tangent1End: corners[index], tangent2End: corners[(index + 1) % corners.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }
}
