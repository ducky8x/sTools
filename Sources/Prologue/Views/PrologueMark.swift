import CoreGraphics
import SwiftUI

// The duck-and-stool mark the Greeting draws (spec 3.7, 4.2 step 1): a duck hanging by one wing from a serif
// stool, in one flat color. The geometry mirrors scripts/generate-icon.swift (the app icon) and is kept to this
// file alone, so it can be replaced wholesale when the icon changes. Coordinates are the icon's: a 1024-point
// square, origin top left, y down.

/// The mark's paths: separate parts to draw as lines, and the one merged silhouette to fill.
enum MarkGeometry {
    /// Each part's outline, in drawing order (the stool, then the duck).
    static let parts: [Path] = [Stool.seat, Stool.bar, Stool.leftLeg, mirrored(Stool.leftLeg), Duck.bodyOutline, Duck.wingPlaced, Duck.eyePlaced]
        .map(Path.init)
    /// The filled mark: one compound path, the eye and the wing's outline cut out.
    static let silhouette = Path(Stool.path.union(Duck.path, using: .winding))
    /// The area the mark covers.
    static let bounds: CGRect = silhouette.boundingRect

    // MARK: Helpers

    static func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    static func shape(_ draw: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        draw(path)
        return path
    }

    static func circle(_ center: CGPoint, _ radius: Double) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
    }

    static func ellipse(_ center: CGPoint, _ rx: Double, _ ry: Double, degrees: Double = 0) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &transform)
    }

    static func box(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double, radius: Double = 0) -> CGPath {
        CGPath(roundedRect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
               cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func mirrored(_ path: CGPath) -> CGPath {
        var flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1024, ty: 0)
        return path.copy(using: &flip)!
    }

    static func union(_ paths: [CGPath]) -> CGPath {
        paths.dropFirst().reduce(paths[0]) { $0.union($1, using: .winding) }
    }

    // MARK: The stool

    enum Stool {
        static let seatLeft = 236.0, seatRight = 788.0
        static let seatTop = 250.0, seatBottom = 316.0
        static let barTop = 346.0, barBottom = 362.0

        static let legTop = barBottom - 2
        static let legTopCenter = 300.0, legTopHalfWidth = 32.0
        static let footTop = 752.0, footBottom = 782.0
        static let legBottomCenter = 230.0, legBottomHalfWidth = 25.0
        static let footHalfWidth = 68.0
        static let bracketHeight = 50.0, bracketReach = 28.0
        static let filletHeight = 34.0, filletReach = 18.0

        static func legEdge(_ side: Double, at y: Double) -> Double {
            let t = (y - legTop) / (footTop - legTop)
            let center = legTopCenter + (legBottomCenter - legTopCenter) * t
            let half = legTopHalfWidth + (legBottomHalfWidth - legTopHalfWidth) * t
            return center + side * half
        }

        static func legSlope(_ side: Double) -> Double {
            (legEdge(side, at: footTop) - legEdge(side, at: legTop)) / (footTop - legTop)
        }

        nonisolated(unsafe) static let seat = box(seatLeft, seatTop, seatRight, seatBottom, radius: 5)
        nonisolated(unsafe) static let bar = box(seatLeft, barTop, seatRight, barBottom, radius: 3)

        /// The left leg: a splayed, tapering stem ending in a bracketed serif foot.
        nonisolated(unsafe) static let leftLeg = shape { path in
            let (filletBottom, bracketTop) = (legTop + filletHeight, footTop - bracketHeight)
            let (outerSlope, innerSlope) = (legSlope(-1), legSlope(1))
            let (filletAlong, bracketAlong) = (filletHeight * 0.55, bracketHeight * 0.55)
            let innerTop = point(legEdge(1, at: legTop) + filletReach, legTop)
            let innerFillet = point(legEdge(1, at: filletBottom), filletBottom)
            let innerBracket = point(legEdge(1, at: bracketTop), bracketTop)
            let outerBracket = point(legEdge(-1, at: bracketTop), bracketTop)
            let innerFoot = point(legEdge(1, at: footTop) + bracketReach, footTop)
            let outerFoot = point(legEdge(-1, at: footTop) - bracketReach, footTop)

            path.move(to: point(legEdge(-1, at: legTop), legTop))
            path.addLine(to: innerTop)
            path.addCurve(to: innerFillet, control1: point(innerTop.x - filletReach * 0.5, legTop),
                          control2: point(innerFillet.x - innerSlope * filletAlong, innerFillet.y - filletAlong))
            path.addLine(to: innerBracket)
            path.addCurve(to: innerFoot,
                          control1: point(innerBracket.x + innerSlope * bracketAlong, innerBracket.y + bracketAlong),
                          control2: point(innerFoot.x - bracketReach * 0.5, footTop))
            path.addLine(to: point(legBottomCenter + footHalfWidth, footTop))
            path.addLine(to: point(legBottomCenter + footHalfWidth, footBottom))
            path.addLine(to: point(legBottomCenter - footHalfWidth, footBottom))
            path.addLine(to: point(legBottomCenter - footHalfWidth, footTop))
            path.addLine(to: outerFoot)
            path.addCurve(to: outerBracket, control1: point(outerFoot.x + bracketReach * 0.5, footTop),
                          control2: point(outerBracket.x + outerSlope * bracketAlong, outerBracket.y + bracketAlong))
            path.closeSubpath()
        }

        nonisolated(unsafe) static let path = union([seat, bar, leftLeg, mirrored(leftLeg)])
    }

    // MARK: The duck

    /// A round-headed duck facing right, hanging under the bar by its near wing, whose feather tips curl over the
    /// bar's top. Drawn around the grip (the top of the bar under the wing tip) and placed there.
    enum Duck {
        static let grip = point(467, Stool.barTop)
        static let scale = 1.0

        static let head = (center: point(110, 130), radius: 55.0)
        static let eye = (center: point(120, 116), radius: 9.5)
        static let wingGap = 11.0

        nonisolated(unsafe) static let wing = shape { path in
            path.move(to: point(50, 170))
            path.addCurve(to: point(38, 16), control1: point(56, 118), control2: point(42, 56))
            path.addLine(to: point(40, 0))
            for (from, to, height) in [(40.0, 21.0, 18.0), (21.0, 2.0, 21.0), (2.0, -18.0, 17.0)] {
                path.addCurve(to: point(to, 0), control1: point(from, -height * 4 / 3), control2: point(to, -height * 4 / 3))
            }
            path.addLine(to: point(-20, 16))
            path.addCurve(to: point(-32, 192), control1: point(-26, 70), control2: point(-36, 140))
            path.addCurve(to: point(50, 170), control1: point(-10, 206), control2: point(30, 198))
            path.closeSubpath()
        }

        nonisolated(unsafe) static let bill = shape { path in
            path.move(to: point(146, 112))
            path.addCurve(to: point(212, 124), control1: point(172, 106), control2: point(204, 110))
            path.addCurve(to: point(188, 152), control1: point(220, 138), control2: point(206, 152))
            path.addCurve(to: point(140, 150), control1: point(170, 152), control2: point(154, 152))
            path.closeSubpath()
        }

        nonisolated(unsafe) static let tail = shape { path in
            path.move(to: point(-76, 214))
            path.addCurve(to: point(-124, 192), control1: point(-96, 210), control2: point(-112, 202))
            path.addCurve(to: point(-86, 274), control1: point(-124, 222), control2: point(-112, 256))
            path.closeSubpath()
        }

        nonisolated(unsafe) static let body = union([
            circle(head.center, head.radius),
            bill,
            ellipse(point(14, 236), 116, 94, degrees: -12),
            tail,
        ])

        static var placement: CGAffineTransform {
            CGAffineTransform(translationX: grip.x, y: grip.y).scaledBy(x: scale, y: scale)
        }

        static func placed(_ path: CGPath) -> CGPath {
            var transform = placement
            return path.copy(using: &transform)!
        }

        nonisolated(unsafe) static let wingOutline = wing.copy(strokingWithWidth: 2 * wingGap, lineCap: .round, lineJoin: .round, miterLimit: 10)

        /// The body as drawn in lines: head, bill, body and tail with the wing's gap cut away.
        nonisolated(unsafe) static let bodyOutline = placed(body.subtracting(wingOutline, using: .winding))
        nonisolated(unsafe) static let wingPlaced = placed(wing)
        nonisolated(unsafe) static let eyePlaced = placed(circle(eye.center, eye.radius))

        nonisolated(unsafe) static let path: CGPath = placed(
            body.subtracting(wingOutline, using: .winding)
                .union(wing, using: .winding)
                .subtracting(circle(eye.center, eye.radius), using: .winding))
    }
}

/// One of the mark's paths, fitted into the shape's rect by the whole mark's bounds, so every part lines up.
struct MarkShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let bounds = MarkGeometry.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let x = rect.midX - bounds.midX * scale
        let y = rect.midY - bounds.midY * scale
        return path.applying(CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale))
    }
}

/// The mark, drawn: `lineProgress` 0…1 draws every part's outline in fine lines, `fillAmount` 0…1 fills it with one
/// flat color while the lines fade.
struct PrologueMark: View {
    var lineProgress: Double
    var fillAmount: Double
    var lineColor: Color
    var fillColor: Color
    var lineWidth: CGFloat = 1

    var body: some View {
        ZStack {
            MarkShape(path: MarkGeometry.silhouette)
                .fill(fillColor)
                .opacity(fillAmount)
            ForEach(MarkGeometry.parts.indices, id: \.self) { index in
                MarkShape(path: MarkGeometry.parts[index])
                    .trim(from: 0, to: partProgress(index))
                    .stroke(lineColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
            .opacity(1 - fillAmount * 0.85)
        }
        .aspectRatio(MarkGeometry.bounds.width / MarkGeometry.bounds.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("The sTools mark: a duck hanging by its wing from a stool")
    }

    /// The stool's parts draw first, the duck's slightly after, all overlapping.
    private func partProgress(_ index: Int) -> CGFloat {
        let count = Double(MarkGeometry.parts.count)
        let start = Double(index) / count * 0.45
        let span = 0.55
        return CGFloat(min(max((lineProgress - start) / span, 0), 1))
    }
}
