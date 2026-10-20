// Draws sTools' app icon and writes the Icon Composer document and the fallback .icns.
//
// Usage: swift scripts/generate-icon.swift <packagingDirectory> [<previewDirectory>]
//
// Writes, under <packagingDirectory>:
//   AppIcon.icon/icon.json         the Icon Composer document: one flat layer, no glass, no shadow
//   AppIcon.icon/Assets/Mark.svg   the mark, one compound path in one color
//   sTools.icns                    the pre-macOS 26 icon, built with iconutil from a temporary .iconset
// With a preview directory it also writes the .icns artwork as preview-<size>.png at 1024, 256, 64, 32, 16.
//
// The mark: a duck hanging by one wing from a stool, in the app's gold on the app's background. The
// stool keeps its serif character: a slab seat over a bar, and splayed legs whose feet flare out in
// bracketed serifs. Every shape is defined once, in 1024-point icon coordinates (origin top left, y down),
// then merged with path operations into one compound path (the eye and the wing's outline are cut out of
// it). That one path is written to the SVG layer and filled for the .icns bitmaps, so the two renderings
// can never drift apart.
//
// In an Icon Composer document the whole 1024-point canvas is the icon plate: macOS 26 masks it and adds
// its own edge. A legacy .icns carries its own plate, so for the .icns the same artwork is scaled into
// Apple's macOS icon grid (an 824-point rounded rectangle centered on the 1024 canvas, 100 points of margin
// for the shadow) and drawn over a plate in the background color.
//
// The output is deterministic: running the script twice produces identical files.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GeneratorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Colors (Sources/STDesign/STPalette.swift)

enum Tone {
    static let background = "#0B0A09"   // STPalette.background
    static let mark = "#D9AE52"         // STPalette.gold, the app's accent
}

// MARK: - Path helpers

func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

/// Builds a path with a closure, so shapes read as a list of strokes of the pen.
func shape(_ draw: (CGMutablePath) -> Void) -> CGPath {
    let path = CGMutablePath()
    draw(path)
    return path
}

func circle(_ center: CGPoint, _ radius: Double) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
           transform: nil)
}

/// An ellipse turned by `degrees` (clockwise on screen, since y points down).
func ellipse(_ center: CGPoint, _ rx: Double, _ ry: Double, degrees: Double = 0) -> CGPath {
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &transform)
}

func box(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double, radius: Double = 0) -> CGPath {
    CGPath(roundedRect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Reflects a path across the icon's vertical center line.
func mirrored(_ path: CGPath) -> CGPath {
    var flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1024, ty: 0)
    return path.copy(using: &flip)!
}

func union(_ paths: [CGPath]) -> CGPath {
    paths.dropFirst().reduce(paths[0]) { $0.union($1, using: .winding) }
}

// MARK: - The stool

enum Stool {
    // The seat: a slab over a bar of the same width, with a gap the duck's wing can curl into.
    static let seatLeft = 236.0, seatRight = 788.0
    static let seatTop = 250.0, seatBottom = 316.0
    static let barTop = 346.0, barBottom = 362.0

    // The left leg (the right one is its mirror image): a tapering stem that splays outward and ends in a
    // serif foot with curved brackets on both sides. A fillet joins the stem to the bar on the inner side,
    // where the joint is acute; the outer joint is already open, so it stays a plain corner.
    static let legTop = barBottom - 2                       // tucked into the bar so no seam shows
    static let legTopCenter = 300.0, legTopHalfWidth = 32.0
    static let footTop = 752.0, footBottom = 782.0
    static let legBottomCenter = 230.0, legBottomHalfWidth = 25.0
    static let footHalfWidth = 68.0
    static let bracketHeight = 50.0, bracketReach = 28.0
    static let filletHeight = 34.0, filletReach = 18.0

    /// x of the left leg's outer (side -1), center (0) or inner (side +1) edge at height y.
    static func legEdge(_ side: Double, at y: Double) -> Double {
        let t = (y - legTop) / (footTop - legTop)
        let center = legTopCenter + (legBottomCenter - legTopCenter) * t
        let half = legTopHalfWidth + (legBottomHalfWidth - legTopHalfWidth) * t
        return center + side * half
    }

    /// dx/dy of a leg edge, so curves can leave the stem along its own direction.
    static func legSlope(_ side: Double) -> Double {
        (legEdge(side, at: footTop) - legEdge(side, at: legTop)) / (footTop - legTop)
    }

    /// The left leg, traced clockwise from its outer top corner.
    static let leftLeg = shape { path in
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

    static let path = union([
        box(seatLeft, seatTop, seatRight, seatBottom, radius: 5),
        box(seatLeft, barTop, seatRight, barBottom, radius: 3),
        leftLeg,
        mirrored(leftLeg),
    ])
}

// MARK: - The duck

/// A round-headed duck facing right that hangs under the bar by its near wing: the wing rises from its
/// back, scalloped with feathers on the trailing edge, and its tip curls over the top of the bar.
///
/// The duck is drawn in its own coordinates, whose origin is the grip (the top of the bar, under the
/// curled wing tip), and placed by `grip` and `scale`. The wing tip's ends sit at y = 0, so they stay on
/// the bar's top edge at any scale.
enum Duck {
    static let grip = point(467, Stool.barTop)
    static let scale = 1.0

    static let head = (center: point(110, 130), radius: 55.0)
    static let eye = (center: point(120, 116), radius: 9.5)
    /// The clear gap that outlines the wing where it passes over the body and beside the head.
    static let wingGap = 11.0

    /// Broad at the root on the duck's back, tapering up to the bar, where three feather tips curl over
    /// the top of the bar like fingers.
    static let wing = shape { path in
        path.move(to: point(50, 170))                                                          // root, front
        path.addCurve(to: point(38, 16), control1: point(56, 118), control2: point(42, 56))    // leading edge
        path.addLine(to: point(40, 0))
        for (from, to, height) in [(40.0, 21.0, 18.0), (21.0, 2.0, 21.0), (2.0, -18.0, 17.0)] {
            // One feather tip: a rounded bump from `from` to `to` that rises `height` above the bar.
            path.addCurve(to: point(to, 0), control1: point(from, -height * 4 / 3), control2: point(to, -height * 4 / 3))
        }
        path.addLine(to: point(-20, 16))
        // The trailing edge runs into the back steeply, so the gap cuts a clean notch rather than a sliver.
        path.addCurve(to: point(-32, 192), control1: point(-26, 70), control2: point(-36, 140))
        path.addCurve(to: point(50, 170), control1: point(-10, 206), control2: point(30, 198))   // root, underside
        path.closeSubpath()
    }

    static let bill = shape { path in
        path.move(to: point(146, 112))
        path.addCurve(to: point(212, 124), control1: point(172, 106), control2: point(204, 110))
        path.addCurve(to: point(188, 152), control1: point(220, 138), control2: point(206, 152))
        path.addCurve(to: point(140, 150), control1: point(170, 152), control2: point(154, 152))
        path.closeSubpath()
    }

    static let tail = shape { path in
        path.move(to: point(-76, 214))
        path.addCurve(to: point(-124, 192), control1: point(-96, 210), control2: point(-112, 202))
        path.addCurve(to: point(-86, 274), control1: point(-124, 222), control2: point(-112, 256))
        path.closeSubpath()
    }

    static let body = union([
        circle(head.center, head.radius),
        bill,
        ellipse(point(14, 236), 116, 94, degrees: -12),      // the body, tail end a little low
        tail,
    ])

    static let path: CGPath = {
        let outline = wing.copy(strokingWithWidth: 2 * wingGap, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let duck = body.subtracting(outline, using: .winding)
            .union(wing, using: .winding)
            .subtracting(circle(eye.center, eye.radius), using: .winding)
        var placement = CGAffineTransform(translationX: grip.x, y: grip.y).scaledBy(x: scale, y: scale)
        return duck.copy(using: &placement)!
    }()
}

let mark = Stool.path.union(Duck.path, using: .winding)

// MARK: - SVG

func number(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

func pathData(_ path: CGPath) -> String {
    var data = ""
    func add(_ command: String, _ points: [CGPoint]) {
        data += command + points.map { "\(number($0.x)) \(number($0.y))" }.joined(separator: " ")
    }
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: add("M", [points[0]])
        case .addLineToPoint: add("L", [points[0]])
        case .addQuadCurveToPoint: add("Q", [points[0], points[1]])
        case .addCurveToPoint: add("C", [points[0], points[1], points[2]])
        case .closeSubpath: data += "Z"
        @unknown default: break
        }
    }
    return data
}

func svg(_ path: CGPath, fill: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <!-- sTools app icon: a duck hanging by one wing from a stool. Generated by scripts/generate-icon.swift; do not edit. -->
      <path fill="\(fill)" d="\(pathData(path))"/>
    </svg>

    """
}

// MARK: - Icon Composer document

func rgb(_ hex: String) -> (Double, Double, Double) {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
}

func iconComposerColor(_ hex: String) -> String {
    let (r, g, b) = rgb(hex)
    return "srgb:" + [r, g, b, 1].map { String(format: "%.5f", $0) }.joined(separator: ",")
}

/// One group with one layer, all flat: no glass, no specular highlight, no shadow, no translucency.
func iconDocument() throws -> Data {
    let document: [String: Any] = [
        "fill": ["solid": iconComposerColor(Tone.background)],
        "groups": [[
            "layers": [["glass": false, "image-name": "Mark.svg", "name": "Mark"] as [String: Any]],
            "shadow": ["kind": "none", "opacity": 0] as [String: Any],
            "specular": false,
            "translucency": ["enabled": false, "value": 0] as [String: Any],
        ] as [String: Any]],
        "supported-platforms": ["squares": ["macOS"]],
    ]
    return try JSONSerialization.data(withJSONObject: document,
                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
}

// MARK: - Bitmaps

func cgColor(_ hex: String) -> CGColor {
    let (r, g, b) = rgb(hex)
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

/// Apple's continuous-corner rounded rectangle (the "squircle" of the macOS icon plate).
func continuousRoundedRect(_ rect: CGRect, radius r: Double) -> CGPath {
    // Control points of one corner in units of r, measured from the corner along the two edges.
    let a = 1.528_664_83, b = 1.088_493_23, c = 0.868_406_89, d = 0.631_493_99
    let e = 0.074_911_00, f = 0.372_823_92, g = 0.169_054_22
    return shape { path in
        /// `dx`, `dy` point from the corner into the rectangle; `alongX` says the path arrives along a horizontal edge.
        func corner(_ origin: CGPoint, _ dx: Double, _ dy: Double, alongX: Bool) {
            func p(_ u: Double, _ v: Double) -> CGPoint {
                alongX ? point(origin.x + dx * u * r, origin.y + dy * v * r)
                       : point(origin.x + dx * v * r, origin.y + dy * u * r)
            }
            path.addLine(to: p(a, 0))
            path.addCurve(to: p(d, e), control1: p(b, 0), control2: p(c, 0))
            path.addCurve(to: p(e, d), control1: p(f, g), control2: p(g, f))
            path.addCurve(to: p(0, a), control1: p(0, c), control2: p(0, b))
        }
        path.move(to: point(rect.minX + a * r, rect.minY))
        corner(point(rect.maxX, rect.minY), -1, 1, alongX: true)
        corner(point(rect.maxX, rect.maxY), -1, -1, alongX: false)
        corner(point(rect.minX, rect.maxY), 1, -1, alongX: true)
        corner(point(rect.minX, rect.minY), 1, 1, alongX: false)
        path.closeSubpath()
    }
}

/// The macOS icon grid: the plate is 824 points square, centered on the 1024 canvas.
let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius = 185.4

/// Renders the legacy (.icns) icon: the plate with the system's usual drop shadow, and the mark on it.
func renderLegacyIcon(pixels: Int) throws -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw GeneratorError("cannot create a \(pixels) px bitmap") }
    let scale = Double(pixels) / 1024
    // Icon coordinates have y pointing down; flip once so every shape is drawn as defined.
    context.translateBy(x: 0, y: Double(pixels))
    context.scaleBy(x: scale, y: -scale)

    context.saveGState()
    // Shadow offsets are in device space, where y points up: a negative height drops the shadow down.
    // Small sizes get a lighter shadow so it does not smudge into a dark halo.
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: pixels >= 128 ? 0.45 : 0.3))
    context.addPath(continuousRoundedRect(plateRect, radius: plateRadius))
    context.setFillColor(cgColor(Tone.background))
    context.fillPath()
    context.restoreGState()

    // The mark is designed on the full 1024 plate; map it onto the 824 plate.
    context.translateBy(x: plateRect.minX, y: plateRect.minY)
    context.scaleBy(x: plateRect.width / 1024, y: plateRect.height / 1024)
    context.addPath(mark)
    context.setFillColor(cgColor(Tone.mark))
    context.fillPath()

    guard let image = context.makeImage() else { throw GeneratorError("cannot finish the \(pixels) px bitmap") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw GeneratorError("cannot create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw GeneratorError("cannot write \(url.path)") }
}

// MARK: - Output

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GeneratorError("\(executable) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
    }
}

func generate(packaging: URL, previews: URL?) throws {
    let fileManager = FileManager.default

    let document = packaging.appendingPathComponent("AppIcon.icon", isDirectory: true)
    let assets = document.appendingPathComponent("Assets", isDirectory: true)
    try? fileManager.removeItem(at: document)
    try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
    try iconDocument().write(to: document.appendingPathComponent("icon.json"), options: .atomic)
    try Data(svg(mark, fill: Tone.mark).utf8).write(to: assets.appendingPathComponent("Mark.svg"), options: .atomic)

    let scratch = fileManager.temporaryDirectory.appendingPathComponent("sTools-icon-\(ProcessInfo.processInfo.processIdentifier)")
    let iconset = scratch.appendingPathComponent("sTools.iconset", isDirectory: true)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: scratch) }
    for points in [16, 32, 128, 256, 512] {
        try writePNG(renderLegacyIcon(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try writePNG(renderLegacyIcon(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    try run("/usr/bin/iconutil", ["--convert", "icns", "--output", packaging.appendingPathComponent("sTools.icns").path, iconset.path])

    if let previews {
        try fileManager.createDirectory(at: previews, withIntermediateDirectories: true)
        for pixels in [1024, 256, 64, 32, 16] {
            try writePNG(renderLegacyIcon(pixels: pixels), to: previews.appendingPathComponent("preview-\(pixels).png"))
        }
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard (1...2).contains(arguments.count) else {
    FileHandle.standardError.write(Data("usage: swift scripts/generate-icon.swift <packagingDirectory> [<previewDirectory>]\n".utf8))
    exit(2)
}
do {
    try generate(packaging: URL(fileURLWithPath: arguments.first!, isDirectory: true),
                 previews: arguments.count == 2 ? URL(fileURLWithPath: arguments.last!, isDirectory: true) : nil)
} catch {
    FileHandle.standardError.write(Data("generate-icon failed: \(error)\n".utf8))
    exit(1)
}
