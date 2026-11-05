import STDesign
import SwiftUI

/// The pointer at its real size on the page's background, drawn from the image macOS would get for this display's
/// scale, with a gold mark on the point that clicks: two ticks that aim at it from outside the pointer, and a dot on it.
struct CursorPreview: View {
    /// The pointer drawn at `scale` alone; nil draws only the background (the Image shape before an image is chosen).
    let cursor: CursorImage?
    let scale: CGFloat

    static let height: CGFloat = 168
    /// How far the ticks start outside the pointer, and how long they are.
    static let tickGap: CGFloat = 5
    static let tickLength: CGFloat = 10

    @Environment(\.stTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            if let cursor, let image = cursor.images.first {
                // On whole points, so each pixel of the image lands on one of the screen's.
                let origin = CGPoint(x: ((proxy.size.width - cursor.size.width) / 2).rounded(.down),
                                     y: ((proxy.size.height - cursor.size.height) / 2).rounded(.down))
                Image(decorative: image, scale: scale)
                    .interpolation(.none)
                    .frame(width: cursor.size.width, height: cursor.size.height)
                    .offset(x: origin.x, y: origin.y)
                mark(at: CGPoint(x: origin.x + cursor.hotSpot.x, y: origin.y + cursor.hotSpot.y), around: cursor.size,
                     from: origin)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(STColor.background)
        .accessibilityElement()
        .accessibilityLabel(Self.spokenLabel)
    }

    static let spokenLabel = "Pointer preview. The gold mark is the point that clicks."

    private func mark(at point: CGPoint, around size: CGSize, from origin: CGPoint) -> some View {
        Canvas { context, _ in
            var ticks = Path()
            let left = origin.x - Self.tickGap
            ticks.move(to: CGPoint(x: left - Self.tickLength, y: point.y))
            ticks.addLine(to: CGPoint(x: left, y: point.y))
            let top = origin.y - Self.tickGap
            ticks.move(to: CGPoint(x: point.x, y: top - Self.tickLength))
            ticks.addLine(to: CGPoint(x: point.x, y: top))
            context.stroke(ticks, with: .color(theme.accent), lineWidth: 1)
            let dot = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), with: .color(STColor.background))
            context.fill(Path(ellipseIn: dot), with: .color(theme.accent))
        }
        .allowsHitTesting(false)
    }
}
