// Draws the sTools DMG window's background and writes the Finder layout that goes with it, from one
// description of that window (`Window` below), so the picture and the icon positions can never disagree.
//
// Usage:
//   swift scripts/dmg-window.swift background <outputDirectory> [--version <x.y.z>] [--preview <file.png>] [--dev]
//   swift scripts/dmg-window.swift ds-store <volumeRoot> [--dev]
//   swift scripts/dmg-window.swift dump <path/to/.DS_Store> [--dev]
//
//   --dev       The dev build's DMG (scripts/build-dmg.sh --dev) instead of the normal one: the window holds
//               sTools Dev.app and says "sTools Dev" where the normal one says "sTools", and its accents (the rule, the
//               arrow, the step numbers) are the dev icon's blue instead of gold. The window's size and the icon
//               positions are the same. Give it to every command, `dump` included, which checks the layout of the
//               app's name.
//
//   background  Writes background.png (1x, 72 dpi), background@2x.png (2x, 144 dpi) and background.tiff, which
//               holds both so it is sharp on Retina displays and is what scripts/build-dmg.sh puts on the disk
//               image. ImageIO writes it, with no tags naming the tool or the source files. --version prints the
//               version on the background; --preview also writes a mock-up of the open window, with the
//               app's and Applications' icons and labels drawn where Finder will put them.
//   ds-store    Writes <volumeRoot>/.DS_Store: window size and chrome, icon view options, icon positions and
//               the background picture, which must already be at <volumeRoot>/.background/background.tiff.
//               Run it on the mounted, writable volume, wherever it is mounted: the background is referenced by an
//               alias and a bookmark that record the volume as mounted at /Volumes/<volume name>, where users see
//               it, plus the volume's identity and the file IDs, which find it wherever it is mounted. The hidden
//               files at the volume's root (.background, .VolumeIcon.icns) get positions far outside the window,
//               so a Finder that shows hidden files does not drop them over the artwork.
//   dump        Prints the records of a .DS_Store file, for checking: the background's alias and bookmark are
//               resolved, and the alias is also checked field by field against the volume holding the file. The
//               last line is `layout ok`, or `layout problem: ...` when the window size or an icon position is not
//               what `Window` describes.
//
// Why write .DS_Store directly: the usual way is AppleScript telling Finder to arrange the window, which
// needs the Automation permission and an on-screen Finder. The file format is documented by the open-source
// ds_store/mac_alias projects (used by dmgbuild) and node's appdmg, which have written DMG layouts this way
// for years: a buddy-allocated file holding a B-tree of (file name, code, typed value) records.
//
// Colors come from Sources/STDesign/STPalette.swift and fonts from Sources/STDesign/Resources/Fonts, so the
// DMG follows the app's design tokens.

import AppKit
import CoreText
import Darwin
import ImageIO
import UniformTypeIdentifiers

// MARK: - The variant

/// Which DMG this is: the normal build's, or the dev build's (`--dev`, found once from the command line).
struct Variant {
    let isDev: Bool

    /// The name the window uses for the app.
    var name: String { isDev ? "sTools Dev" : "sTools" }
    var appName: String { name + ".app" }
    /// The app's .icns, which the preview draws where Finder will draw the app's icon.
    var iconsPath: String { isDev ? "packaging/dev/sTools.icns" : "packaging/sTools.icns" }
}

let variant = Variant(isDev: CommandLine.arguments.contains("--dev"))

// MARK: - The window

/// The DMG window, in points, with the origin at the top left of the window's content area.
enum Window {
    /// The designed content area: what the artwork is laid out in and what a person sees whole.
    static let size = CGSize(width: 640, height: 448)
    /// Finder stores the whole window frame, title bar included, so the frame is the content plus a title bar.
    /// A plain title bar is 28 pt on macOS 15 and 32 pt on macOS 27 (measured).
    static let titleBarHeight: CGFloat = 32
    static let smallestTitleBarHeight: CGFloat = 28
    /// Room for the bars a Finder window may take from the content area. Finder on macOS 27 does not obey a disk
    /// image's own ShowTabView, ShowPathbar and ShowStatusBar settings (they stay in the .DS_Store in case an older
    /// macOS reads them): it follows the person's View menu, so a window may lose a tab bar (28 pt, and an 8 pt gap
    /// under it), a path bar (28 pt) and a status bar (28 pt) from the content area. The frame is 64 pt taller than
    /// the content, and the picture runs on in plain background under the artwork, so a Finder with a tab bar and a
    /// path bar still shows the whole 640 x 448 artwork (a status bar as well cuts only the empty strip under the
    /// steps) and one without them shows that plain strip.
    static let barsAllowance: CGFloat = 64
    /// The whole window, title bar and room for bars included.
    static let frameSize = CGSize(width: size.width, height: size.height + titleBarHeight + barsAllowance)
    /// The picture: the artwork on top, then plain background down to the largest content area the window can have
    /// (the frame less the smallest title bar), so no bare strip shows below it.
    static let canvasSize = CGSize(width: size.width, height: frameSize.height - smallestTitleBarHeight)
    /// Where the window opens: its bottom-left corner, measured from the bottom left of the main screen. Low enough
    /// that the taller window still fits under the menu bar of a 13-inch MacBook's scaled screen.
    static let screenOrigin = CGPoint(x: 480, y: 160)

    static let iconSize: CGFloat = 96
    static let labelTextSize: CGFloat = 13

    static let appName = variant.appName
    static let applicationsName = "Applications"
    /// Icon centers.
    static let appCenter = CGPoint(x: 176, y: 204)
    static let applicationsCenter = CGPoint(x: 464, y: 204)

    static let backgroundFolder = ".background"
    static let backgroundFile = "background.tiff"
    static let volumeIconFile = ".VolumeIcon.icns"

    /// Files at the volume's root that Finder hides by their dot but lists when it shows hidden files (Shift-Command-.).
    /// With no position they land in a free grid slot, over the artwork (in the old layout, over the steps). They get
    /// positions far to the right of the window instead, on the icons' own row. Finder stretches the scrollable area
    /// over every item wherever it is, so the few people who show hidden files see a horizontal scroll bar along the
    /// bottom edge (under the last step, over the plain strip) and never a vertical one; no position hides an item
    /// without scrolling.
    static let hiddenItems = [backgroundFolder, volumeIconFile]
    static func hiddenItemCenter(_ index: Int) -> CGPoint {
        CGPoint(x: 2000 + 200 * CGFloat(index), y: appCenter.y)
    }

    static let margin: CGFloat = 48
}

// MARK: - Errors and paths

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The repository root, found from this file's own location.
let repositoryRoot = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Palette (read from STPalette.swift)

/// The app's color tokens, parsed from `public static let <name> = "#RRGGBB"` lines.
func loadPalette() throws -> [String: CGColor] {
    let url = repositoryRoot.appendingPathComponent("Sources/STDesign/STPalette.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: ##"static let (\w+) = "#([0-9A-Fa-f]{6})""##)
    var palette: [String: CGColor] = [:]
    for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
        guard let name = Range(match.range(at: 1), in: source), let hex = Range(match.range(at: 2), in: source),
              let value = UInt32(source[hex], radix: 16) else { continue }
        palette[String(source[name])] = CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255,
                                                green: CGFloat(value >> 8 & 0xFF) / 255,
                                                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    for token in ["background", "surface", "ink", "inkSecondary", "inkTertiary", "gold", "goldStroke", "rule"]
    where palette[token] == nil {
        throw Failure("STPalette.swift has no \(token) color")
    }
    return palette
}

/// The color of the rule, the arrow and the step numbers: the app's gold, or for the dev DMG the blue of the dev
/// icon's mark, read from the committed icon (scripts/generate-icon.swift writes it) so the two can never differ.
func loadAccent(palette: [String: CGColor]) throws -> CGColor {
    guard variant.isDev else { return palette["gold"]! }
    let url = repositoryRoot.appendingPathComponent("packaging/dev/AppIcon.icon/Assets/Mark.svg")
    let source = try String(contentsOf: url, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: ##"fill="#([0-9A-Fa-f]{6})""##)
    guard let match = pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let hex = Range(match.range(at: 1), in: source), let value = UInt32(source[hex], radix: 16) else {
        throw Failure("\(url.path) has no fill color; make the dev icon with scripts/generate-icon.swift --tint blue packaging/dev")
    }
    return CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

// MARK: - Fonts

enum Fonts {
    static let directory = repositoryRoot.appendingPathComponent("Sources/STDesign/Resources/Fonts")

    static func descriptor(_ file: String) throws -> CTFontDescriptor {
        let url = directory.appendingPathComponent(file)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { throw Failure("cannot load the font \(url.path)") }
        return first
    }

    /// A font from a bundled file, with variable-font axes (four-letter tags) and OpenType features.
    static func font(_ file: String, size: CGFloat, axes: [String: Double] = [:], features: [String] = []) throws -> CTFont {
        var attributes: [CFString: Any] = [:]
        if !axes.isEmpty {
            var variation: [NSNumber: NSNumber] = [:]
            for (tag, value) in axes { variation[NSNumber(value: fourCharCode(tag))] = NSNumber(value: value) }
            attributes[kCTFontVariationAttribute] = variation
        }
        if !features.isEmpty {
            attributes[kCTFontFeatureSettingsAttribute] = features.map {
                [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 1] as [CFString: Any]
            }
        }
        let base = try descriptor(file)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Bodoni Moda, the face the app sets its titles in (`STFont.display`): weight 400, with the optical-size axis at
    /// its display maximum, 96. The same two numbers as the app, so the window's title looks like a tool page's.
    static func display(_ size: CGFloat) throws -> CTFont {
        try font("BodoniModa[opsz,wght].ttf", size: size, axes: ["wght": 400, "opsz": 96])
    }

    /// Source Serif 4, the app's text face, at an optical size matching the point size. Only the roman is
    /// bundled, so italic is the roman slanted, which is what the app's `.italic()` text looks like too.
    static func text(_ size: CGFloat, weight: Double = 400, italic: Bool = false, smallCaps: Bool = false) throws -> CTFont {
        let font = try self.font("SourceSerif4[opsz,wght].ttf", size: size,
                                 axes: ["wght": weight, "opsz": min(max(Double(size), 8), 60)],
                                 features: smallCaps ? ["c2sc", "smcp"] : [])
        guard italic else { return font }
        // `Canvas` flips y, so the skew that leans glyphs to the right is negative here.
        var slant = CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, size, &slant, nil)
    }
}

func fourCharCode(_ code: String) -> UInt32 {
    let bytes = Array(code.utf8)
    precondition(bytes.count == 4, "four-character code expected, got \(code)")
    return bytes.reduce(0) { $0 << 8 | UInt32($1) }
}

// MARK: - Drawing

/// A bitmap in sRGB at `scale` pixels per point, with a top-left origin in points.
final class Canvas {
    let context: CGContext
    let size: CGSize
    let scale: CGFloat

    init(size: CGSize, scale: CGFloat) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure("cannot create a \(size.width * scale) x \(size.height * scale) bitmap") }
        self.context = context
        self.size = size
        self.scale = scale
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setShouldSmoothFonts(false)
        context.interpolationQuality = .high
    }

    enum Alignment { case left, center, right }

    /// A single line of text. `kern` is extra spacing between letters, in points.
    func line(_ text: String, font: CTFont, color: CGColor, kern: CGFloat = 0) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if kern != 0 { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    func width(of line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    /// Draws a line of text with its baseline at `baseline`; returns the x where it ends.
    @discardableResult
    func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat, alignment: Alignment = .left) -> CGFloat {
        let width = self.width(of: line)
        let start = switch alignment {
        case .left: x
        case .center: x - width / 2
        case .right: x - width
        }
        context.textPosition = CGPoint(x: start, y: baseline)
        CTLineDraw(line, context)
        return start + width
    }

    func image() throws -> CGImage {
        guard let image = context.makeImage() else { throw Failure("cannot read the bitmap back") }
        return image
    }
}

func writePNG(_ image: CGImage, to url: URL, dpi: Double) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("cannot write \(url.path)") }
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw Failure("cannot write \(url.path)") }
}

/// One TIFF holding each image at its resolution (LZW-compressed), as `tiffutil -cathidpicheck` makes, but without
/// its Software and ImageDescription tags (the tool's version and the source files' names).
func writeTIFF(_ images: [(image: CGImage, dpi: Double)], to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString,
                                                            images.count, nil)
    else { throw Failure("cannot write \(url.path)") }
    for (image, dpi) in images {
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5] as CFDictionary,  // LZW
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { throw Failure("cannot write \(url.path)") }
}

/// What drawing the background measured, for the build to print.
struct BackgroundFit {
    /// The right edge of the widest line of text, in points from the left of the window.
    var rightmostText: CGFloat = 0
    /// Where the last numbered step's baseline sits, in points from the top of the window.
    var lastBaseline: CGFloat = 0
}

/// The background: wordmark, gilt rule and standfirst; a gold arrow from the app to Applications; and the
/// one-time steps for opening an app that isn't notarized. The artwork fills `Window.size`; the plain background
/// continues under it to the bottom of the canvas. The dev DMG says "sTools Dev" for the app and draws the accents
/// (gold above) in blue.
@discardableResult
func drawBackground(on canvas: Canvas, palette: [String: CGColor], accent: CGColor, version: String?) throws -> BackgroundFit {
    let context = canvas.context
    let width = Window.size.width
    let margin = Window.margin
    let color = { (token: String) in palette[token]! }
    var fit = BackgroundFit()

    /// A line of text that must end before the right margin (544 pt of line in a 640 pt window).
    func text(_ string: String, font: CTFont, color: CGColor, x: CGFloat, baseline: CGFloat) {
        let line = canvas.line(string, font: font, color: color)
        let end = x + canvas.width(of: line)
        precondition(end <= width - margin, "\"\(string)\" runs \(Int(end - (width - margin)) + 1) pt past the right margin")
        fit.rightmostText = max(fit.rightmostText, end)
        canvas.draw(line, x: x, baseline: baseline)
    }

    context.setFillColor(color("background"))
    context.fill(CGRect(origin: .zero, size: canvas.size))

    // Header: the wordmark, the version across from it, a gilt rule and the standfirst (as on a tool page). The
    // wordmark is a page title: Bodoni Moda at 40 pt with no extra tracking (`STTextStyle.pageTitle`).
    let titleBaseline: CGFloat = 74
    canvas.draw(canvas.line(variant.name, font: try Fonts.display(40), color: color("ink")),
                x: margin - 2, baseline: titleBaseline)
    if let version {
        let label = canvas.line("Version \(version)", font: try Fonts.text(12, weight: 600, smallCaps: true),
                                color: color("inkTertiary"), kern: 12 * 0.04)
        canvas.draw(label, x: width - margin, baseline: titleBaseline, alignment: .right)
    }
    context.setFillColor(accent)
    context.fill(CGRect(x: margin, y: titleBaseline + 14, width: width - 2 * margin, height: 1))
    text("Drag \(variant.name) into the Applications folder.",
         font: try Fonts.text(16, italic: true), color: color("inkSecondary"), x: margin, baseline: titleBaseline + 42)

    // The arrow, between the two icons' slots.
    let half = Window.iconSize / 2
    let arrowY = Window.appCenter.y
    let start = Window.appCenter.x + half + 30
    let tip = Window.applicationsCenter.x - half - 30
    drawArrow(in: context, from: start, to: tip, y: arrowY, color: accent)

    // First open: a hairline, a short reason and three numbered steps.
    let sectionTop: CGFloat = 300
    context.setFillColor(color("rule"))
    context.fill(CGRect(x: margin, y: sectionTop, width: width - 2 * margin, height: 1))

    let labelBaseline = sectionTop + 30
    text("Because \(variant.name) isn\u{2019}t notarized, macOS blocks it on its first open.",
         font: try Fonts.text(14, italic: true), color: color("inkTertiary"), x: margin, baseline: labelBaseline)

    // The dev name is four letters longer, which would run this line past the right margin, so it drops its "and".
    let steps = [
        variant.isDev
            ? "Open \(variant.name) from the Applications folder, then click Done on the popup."
            : "Open \(variant.name) from the Applications folder, and then click Done on the popup.",
        "Go to System Settings \u{25B8} Privacy & Security.",
        "Click Open Anyway, then confirm.",
    ]
    let numberFont = try Fonts.text(14, weight: 500)
    let stepFont = try Fonts.text(14)
    for (index, step) in steps.enumerated() {
        let baseline = labelBaseline + 28 + CGFloat(index) * 22
        text("\(index + 1)", font: numberFont, color: accent, x: margin, baseline: baseline)
        text(step, font: stepFont, color: color("ink"), x: margin + 20, baseline: baseline)
    }
    let lastBaseline = labelBaseline + 28 + CGFloat(steps.count - 1) * 22
    precondition(lastBaseline + 6 <= Window.size.height - 32, "the steps run too close to the bottom edge")
    fit.lastBaseline = lastBaseline
    return fit
}

/// A fine gold arrow: a small dot where the app sits, a hairline shaft and a swept, pointed head.
func drawArrow(in context: CGContext, from start: CGFloat, to tip: CGFloat, y: CGFloat, color: CGColor) {
    context.saveGState()
    context.setFillColor(color)
    context.setStrokeColor(color)

    context.fillEllipse(in: CGRect(x: start - 2.5, y: y - 2.5, width: 5, height: 5))

    let headLength: CGFloat = 13
    let headHalfHeight: CGFloat = 6.5
    context.setLineWidth(1.25)
    context.setLineCap(.butt)
    context.move(to: CGPoint(x: start + 6, y: y))
    context.addLine(to: CGPoint(x: tip - headLength + 3, y: y))
    context.strokePath()

    // Head: two curved barbs meeting at the tip, closed by a shallow notch.
    let head = CGMutablePath()
    head.move(to: CGPoint(x: tip, y: y))
    head.addQuadCurve(to: CGPoint(x: tip - headLength, y: y - headHalfHeight),
                      control: CGPoint(x: tip - headLength * 0.45, y: y - headHalfHeight * 0.35))
    head.addQuadCurve(to: CGPoint(x: tip - headLength, y: y + headHalfHeight),
                      control: CGPoint(x: tip - headLength * 0.55, y: y))
    head.addQuadCurve(to: CGPoint(x: tip, y: y),
                      control: CGPoint(x: tip - headLength * 0.45, y: y + headHalfHeight * 0.35))
    head.closeSubpath()
    context.addPath(head)
    context.fillPath()
    context.restoreGState()
}

/// A mock-up of the open window: the background with the two icons and their labels where Finder draws them
/// (white labels, as Finder uses on a dark background). For reviewing the design only.
func drawPreviewItems(on canvas: Canvas) throws {
    let iconsFile = repositoryRoot.appendingPathComponent(variant.iconsPath).path
    let appIcon = FileManager.default.fileExists(atPath: iconsFile)
        ? NSImage(contentsOfFile: iconsFile)
        : NSWorkspace.shared.icon(forFile: repositoryRoot.appendingPathComponent("build/\(variant.appName)").path)
    let items: [(NSImage?, CGPoint, String)] = [
        (appIcon, Window.appCenter, variant.name),
        (NSWorkspace.shared.icon(forFile: "/Applications"), Window.applicationsCenter, Window.applicationsName),
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas.context, flipped: true)
    let labelFont = CTFontCreateUIFontForLanguage(.system, Window.labelTextSize, nil)!
    for (icon, center, label) in items {
        let half = Window.iconSize / 2
        icon?.draw(in: CGRect(x: center.x - half, y: center.y - half, width: Window.iconSize, height: Window.iconSize),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        canvas.draw(canvas.line(label, font: labelFont, color: CGColor(gray: 1, alpha: 1)),
                    x: center.x, baseline: center.y + half + 18, alignment: .center)
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// Marks the bottom of the artwork (448 pt, all a Finder with a tab bar and a path bar shows); a Finder without
/// bars shows the plain strip under the line too. For reviewing the design only.
func drawPreviewGuides(on canvas: Canvas) {
    let context = canvas.context
    context.saveGState()
    context.setStrokeColor(CGColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 0.7))
    context.setLineWidth(1)
    context.setLineDash(phase: 0, lengths: [4, 4])
    context.move(to: CGPoint(x: 0, y: Window.size.height))
    context.addLine(to: CGPoint(x: canvas.size.width, y: Window.size.height))
    context.strokePath()
    context.restoreGState()
}

func generateBackground(outputDirectory: URL, version: String?, preview: URL?) throws {
    let palette = try loadPalette()
    let accent = try loadAccent(palette: palette)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var images: [(image: CGImage, dpi: Double)] = []
    for scale in [1, 2] {
        let canvas = try Canvas(size: Window.canvasSize, scale: CGFloat(scale))
        let fit = try drawBackground(on: canvas, palette: palette, accent: accent, version: version)
        if scale == 1 {
            print("text fits: widest line ends \(Int(fit.rightmostText.rounded(.up))) pt of \(Int(Window.size.width - Window.margin)), "
                  + "last step's baseline \(Int(fit.lastBaseline)) pt of \(Int(Window.size.height))")
        }
        let name = scale == 1 ? "background.png" : "background@2x.png"
        let image = try canvas.image()
        try writePNG(image, to: outputDirectory.appendingPathComponent(name), dpi: 72 * Double(scale))
        images.append((image, 72 * Double(scale)))
        print("wrote \(outputDirectory.appendingPathComponent(name).path)")
    }
    let tiff = outputDirectory.appendingPathComponent(Window.backgroundFile)
    try writeTIFF(images, to: tiff)
    print("wrote \(tiff.path)")
    if let preview {
        let canvas = try Canvas(size: Window.canvasSize, scale: 2)
        try drawBackground(on: canvas, palette: palette, accent: accent, version: version)
        try drawPreviewItems(on: canvas)
        drawPreviewGuides(on: canvas)
        try writePNG(try canvas.image(), to: preview, dpi: 144)
        print("wrote \(preview.path)")
    }
}

// MARK: - Binary writing

struct Bytes {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func fourCC(_ code: String) { u32(fourCharCode(code)) }
    mutating func zeros(_ count: Int) { data.append(Data(count: count)) }

    /// A Pascal string in a fixed-size field: a length byte, then at most `field - 1` bytes, zero-padded.
    mutating func pascal(_ string: String, field: Int) {
        let bytes = Array(Data(string.utf8).prefix(field - 1))
        u8(UInt8(bytes.count))
        data.append(contentsOf: bytes)
        zeros(field - 1 - bytes.count)
    }
}

struct Reader {
    let data: Data
    var offset: Int

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw Failure("truncated data at \(offset)") }
        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func fourCC() throws -> String { String(decoding: try take(4), as: UTF8.self) }
}

// MARK: - .DS_Store

/// One record: a file name in the folder ("." is the folder itself), a four-letter code and a typed value.
struct DSRecord {
    enum Value {
        case long(UInt32)
        case bool(Bool)
        case type(String)
        case blob(Data)
        case ustr(String)
    }

    let name: String
    let code: String
    let value: Value

    func encode(into bytes: inout Bytes) {
        let units = Array(name.utf16)
        bytes.u32(UInt32(units.count))
        for unit in units { bytes.u16(unit) }
        bytes.fourCC(code)
        switch value {
        case .long(let number): bytes.fourCC("long"); bytes.u32(number)
        case .bool(let flag): bytes.fourCC("bool"); bytes.u8(flag ? 1 : 0)
        case .type(let code): bytes.fourCC("type"); bytes.fourCC(code)
        case .blob(let data): bytes.fourCC("blob"); bytes.u32(UInt32(data.count)); bytes.append(data)
        case .ustr(let string):
            let units = Array(string.utf16)
            bytes.fourCC("ustr"); bytes.u32(UInt32(units.count))
            for unit in units { bytes.u16(unit) }
        }
    }

    /// Finder's order: file names compared case-insensitively, then codes.
    static func ordered(_ lhs: DSRecord, _ rhs: DSRecord) -> Bool {
        let (left, right) = (lhs.name.lowercased(), rhs.name.lowercased())
        if left != right { return left < right }
        return fourCharCode(lhs.code) < fourCharCode(rhs.code)
    }
}

enum DSStore {
    static let pageSize = 4096

    /// The whole file: a 4-byte prefix, then a buddy-allocated space (offsets below count from byte 4) holding
    /// a 32-byte header and, as Finder lays them out, block 0: the allocator's own root block (the block table,
    /// the table of contents and the free lists), block 1: the B-tree's "DSDB" header, block 2: one leaf node.
    /// A handful of records always fits in one leaf, so the tree has no internal nodes.
    static func encode(_ records: [DSRecord]) throws -> Data {
        var node = Bytes()
        node.u32(0)  // 0: a leaf
        node.u32(UInt32(records.count))
        for record in records.sorted(by: DSRecord.ordered) { record.encode(into: &node) }
        guard node.data.count <= pageSize else {
            throw Failure("the layout records need \(node.data.count) bytes, more than one \(pageSize)-byte node")
        }

        // Buddy allocation: blocks are powers of two (at least 32 bytes) aligned to their size; an address is
        // the offset with log2(size) in its low five bits.
        var free = [[UInt32]](repeating: [], count: 32)
        free[31] = [0]
        func allocate(_ width: Int) -> UInt32 {
            var level = width
            while free[level].isEmpty { level += 1 }
            while level > width {
                let offset = free[level].removeFirst()
                level -= 1
                free[level] = [offset, offset | (1 << UInt32(level))]
            }
            return free[width].removeFirst()
        }
        func width(for byteCount: Int) -> Int { max(5, Int.bitWidth - (byteCount - 1).leadingZeroBitCount) }
        let rootWidth = 11
        let nodeWidth = width(for: node.data.count)
        let headerOffset = allocate(5)
        let rootOffset = allocate(rootWidth)
        let dsdbOffset = allocate(5)
        let nodeOffset = allocate(nodeWidth)
        precondition(headerOffset == 0)
        let addresses: [UInt32] = [rootOffset | UInt32(rootWidth), dsdbOffset | 5, nodeOffset | UInt32(nodeWidth)]

        var dsdb = Bytes()
        dsdb.u32(2)  // root node: block 2
        dsdb.u32(0)  // levels below the root
        dsdb.u32(UInt32(records.count))
        dsdb.u32(1)  // nodes
        dsdb.u32(UInt32(pageSize))

        var root = Bytes()
        root.u32(UInt32(addresses.count))
        root.u32(0)
        for index in 0..<256 { root.u32(index < addresses.count ? addresses[index] : 0) }
        root.u32(1)  // table of contents: DSDB -> block 1
        root.u8(4)
        root.append(Data("DSDB".utf8))
        root.u32(1)
        for list in free {
            root.u32(UInt32(list.count))
            for offset in list { root.u32(offset) }
        }
        precondition(root.data.count <= 1 << rootWidth)

        let end = addresses.map { Int($0 & ~0x1F) + 1 << Int($0 & 0x1F) }.max()!
        var space = Data(count: end)
        func place(_ bytes: Data, at offset: UInt32) {
            space.replaceSubrange(Int(offset)..<(Int(offset) + bytes.count), with: bytes)
        }
        var header = Bytes()
        header.append(Data("Bud1".utf8))
        header.u32(rootOffset)
        header.u32(1 << UInt32(rootWidth))  // the root block's size, as Finder writes it
        header.u32(rootOffset)
        header.u32(addresses[2])  // Finder repeats the node's address here; the rest is zero
        header.zeros(12)
        place(header.data, at: headerOffset)
        place(root.data, at: rootOffset)
        place(dsdb.data, at: dsdbOffset)
        place(node.data, at: nodeOffset)

        var file = Bytes()
        file.u32(1)
        file.append(space)
        return file.data
    }

    static func decode(_ file: Data) throws -> [DSRecord] {
        var reader = Reader(data: file, offset: 0)
        guard try reader.u32() == 1, try reader.fourCC() == "Bud1" else { throw Failure("not a .DS_Store file") }
        let rootOffset = try reader.u32()
        _ = try reader.u32()
        guard try reader.u32() == rootOffset else { throw Failure("the header's root offsets disagree") }

        var root = Reader(data: file, offset: Int(rootOffset) + 4)
        let count = Int(try root.u32())
        _ = try root.u32()
        var addresses: [UInt32] = []
        for _ in 0..<((count + 255) / 256 * 256) { addresses.append(try root.u32()) }
        addresses = Array(addresses.prefix(count))
        var contents: [String: UInt32] = [:]
        for _ in 0..<(try root.u32()) {
            let name = String(decoding: try root.take(Int(try root.u8())), as: UTF8.self)
            contents[name] = try root.u32()
        }
        guard let dsdb = contents["DSDB"], Int(dsdb) < addresses.count else { throw Failure("no DSDB block") }

        func block(_ number: UInt32) throws -> Reader {
            guard Int(number) < addresses.count else { throw Failure("no block \(number)") }
            return Reader(data: file, offset: Int(addresses[Int(number)] & ~0x1F) + 4)
        }
        var header = try block(dsdb)
        let rootNode = try header.u32()

        var records: [DSRecord] = []
        func walk(_ number: UInt32, depth: Int) throws {
            guard depth < 32 else { throw Failure("the B-tree is too deep") }
            var node = try block(number)
            let next = try node.u32()
            let count = try node.u32()
            for _ in 0..<count {
                if next != 0 { try walk(try node.u32(), depth: depth + 1) }
                records.append(try decodeRecord(&node))
            }
            if next != 0 { try walk(next, depth: depth + 1) }
        }
        try walk(rootNode, depth: 0)
        return records
    }

    static func decodeRecord(_ reader: inout Reader) throws -> DSRecord {
        let length = Int(try reader.u32())
        let nameData = try reader.take(length * 2)
        let units = stride(from: 0, to: nameData.count, by: 2).map {
            UInt16(nameData[nameData.startIndex + $0]) << 8 | UInt16(nameData[nameData.startIndex + $0 + 1])
        }
        let name = String(decoding: units, as: UTF16.self)
        let code = try reader.fourCC()
        let value: DSRecord.Value
        switch try reader.fourCC() {
        case "long", "shor": value = .long(try reader.u32())
        case "bool": value = .bool(try reader.u8() != 0)
        case "type": value = .type(try reader.fourCC())
        case "blob": value = .blob(try reader.take(Int(try reader.u32())))
        case "ustr":
            let data = try reader.take(Int(try reader.u32()) * 2)
            let units = stride(from: 0, to: data.count, by: 2).map {
                UInt16(data[data.startIndex + $0]) << 8 | UInt16(data[data.startIndex + $0 + 1])
            }
            value = .ustr(String(decoding: units, as: UTF16.self))
        case "comp", "dutc": value = .long(UInt32(truncatingIfNeeded: try reader.u64()))
        case let other: throw Failure("unknown record type \(other)")
        }
        return DSRecord(name: name, code: code, value: value)
    }
}

// MARK: - Alias record

/// Where a file is: its volume, mounted now at `mountPoint` and recorded as mounted at `recordedMountPoint`
/// (/Volumes/<volume name>, where users see it), and the file's path below the volume's root.
struct VolumeFile {
    let file: URL
    let mountPoint: String
    let recordedMountPoint: String
    let relative: String
    let volumeName: String
    let volumeCreated: Date
    let fileCreated: Date

    init(_ file: URL) throws {
        // As the file system spells it (/private/var/..., not /var/...), like the mount point below.
        guard let resolved = realpath(file.path, nil) else { throw Failure("cannot find \(file.path)") }
        let path = String(cString: resolved)
        free(resolved)
        var volumeStat = statfs()
        guard statfs(path, &volumeStat) == 0 else { throw Failure("cannot find the volume of \(path)") }
        let mountPoint = withUnsafePointer(to: &volumeStat.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let volume = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let volumeValues = try volume.resourceValues(forKeys: [.volumeNameKey, .creationDateKey])
        let fileValues = try file.resourceValues(forKeys: [.creationDateKey])
        guard let volumeName = volumeValues.volumeName, let volumeCreated = volumeValues.creationDate,
              let fileCreated = fileValues.creationDate else { throw Failure("cannot read the dates of \(path)") }
        guard path.hasPrefix(mountPoint + "/") else { throw Failure("\(path) is not under \(mountPoint)") }
        guard !volumeName.contains("/") else { throw Failure("the volume name \(volumeName) holds a slash") }
        self.file = file
        self.mountPoint = mountPoint
        self.recordedMountPoint = "/Volumes/" + volumeName
        self.relative = String(path.dropFirst(mountPoint.count + 1))
        self.volumeName = volumeName
        self.volumeCreated = volumeCreated
        self.fileCreated = fileCreated
    }

    /// The inode (on HFS+, catalog node ID) of the volume's root and of each folder and file down to the file.
    func ids() throws -> (root: UInt64, below: [UInt64]) {
        var info = stat()
        guard stat(mountPoint, &info) == 0 else { throw Failure("cannot stat \(mountPoint)") }
        let root = UInt64(info.st_ino)
        var below: [UInt64] = []
        var walked = mountPoint
        for component in relative.split(separator: "/") {
            walked += "/" + component
            guard stat(walked, &info) == 0 else { throw Failure("cannot stat \(walked)") }
            below.append(UInt64(info.st_ino))
        }
        return (root, below)
    }
}

/// A classic Mac OS alias record (version 2) for a file on a mounted volume, as Finder stores in
/// `icvp.backgroundImageAlias`. Layout as written by Finder and documented by the mac_alias project: a
/// 150-byte fixed part, then tagged fields, each padded to an even length, ending with tag -1. It records the volume
/// as mounted at /Volumes/<volume name>, not where it is mounted while the alias is written.
func aliasRecord(for file: URL) throws -> Data {
    let location = try VolumeFile(file)
    let path = file.path
    var fileStat = stat()
    var parentStat = stat()
    let parent = file.deletingLastPathComponent()
    guard stat(path, &fileStat) == 0, stat(parent.path, &parentStat) == 0 else { throw Failure("cannot stat \(path)") }
    let mountPoint = location.mountPoint
    let volumeName = location.volumeName
    let volumeCreated = location.volumeCreated
    let fileCreated = location.fileCreated
    let relative = location.relative

    // HFS+ dates count seconds from 1904; on HFS+ an inode number is the catalog node ID.
    func macSeconds(_ date: Date) -> Double { date.timeIntervalSince1970 + 2_082_844_800 }
    let components = relative.split(separator: "/").map(String.init)
    var folderIDs: [UInt32] = []
    var walked = mountPoint
    for component in components.dropLast() {
        walked += "/" + component
        var folder = stat()
        guard stat(walked, &folder) == 0 else { throw Failure("cannot stat \(walked)") }
        folderIDs.append(UInt32(truncatingIfNeeded: folder.st_ino))
    }

    var bytes = Bytes()
    bytes.zeros(4)  // application-specific information
    bytes.u16(0)  // total length, filled in at the end
    bytes.u16(2)  // version
    bytes.u16(0)  // kind: file
    bytes.pascal(volumeName.replacingOccurrences(of: ":", with: "/"), field: 28)
    bytes.u32(UInt32(macSeconds(volumeCreated)))
    bytes.append(Data("H+".utf8))
    bytes.u16(0)  // disk type: fixed
    bytes.u32(UInt32(truncatingIfNeeded: parentStat.st_ino))
    bytes.pascal(file.lastPathComponent.replacingOccurrences(of: ":", with: "/"), field: 64)
    bytes.u32(UInt32(truncatingIfNeeded: fileStat.st_ino))
    bytes.u32(UInt32(macSeconds(fileCreated)))
    bytes.zeros(8)  // creator and type codes
    bytes.i16(-1)  // levels from
    bytes.i16(-1)  // levels to
    bytes.u32(0)  // volume attributes
    bytes.zeros(2)  // file system ID
    bytes.zeros(10)
    precondition(bytes.data.count == 150)

    func tag(_ number: Int16, _ payload: Data) {
        bytes.i16(number)
        bytes.u16(UInt16(payload.count))
        bytes.append(payload)
        if payload.count % 2 == 1 { bytes.u8(0) }
    }
    func utf16Payload(_ string: String) -> Data {
        var payload = Bytes()
        let units = Array(string.utf16)
        payload.u16(UInt16(units.count))
        for unit in units { payload.u16(unit) }
        return payload.data
    }
    tag(0, Data(parent.lastPathComponent.replacingOccurrences(of: ":", with: "/").utf8))  // folder name
    var dates = Bytes()
    dates.u64(UInt64(macSeconds(volumeCreated) * 65536))
    tag(16, dates.data)  // volume creation date, 1/65536 s
    dates = Bytes()
    dates.u64(UInt64(macSeconds(fileCreated) * 65536))
    tag(17, dates.data)  // file creation date, 1/65536 s
    var ids = Bytes()
    for id in folderIDs { ids.u32(id) }
    tag(1, ids.data)  // folder IDs down to the file
    let carbon = components.map { $0.replacingOccurrences(of: ":", with: "/") }
    tag(2, Data((volumeName + ":" + carbon.joined(separator: ":\0")).utf8))  // Carbon path, as Finder writes it
    tag(14, utf16Payload(file.lastPathComponent))  // file name
    tag(15, utf16Payload(volumeName))  // volume name
    tag(18, Data(("/" + relative).utf8))  // path from the volume root
    tag(19, Data(location.recordedMountPoint.utf8))  // mount point
    bytes.i16(-1)
    bytes.u16(0)

    var data = bytes.data
    let length = UInt16(data.count)
    data[4] = UInt8(length >> 8)
    data[5] = UInt8(length & 0xFF)
    return data
}

// MARK: - Bookmark

/// A bookmark to a file on a mounted volume, as Finder stores in `pBBk`, written field by field.
///
/// The system's own `bookmarkData(...)` also records the Mac that made it: for a volume on a disk image, a second
/// bookmark to the image file (its path, in the per-user temporary folder) and to the startup volume (its name,
/// UUID, size and dates), and sandbox tokens naming those paths. This one keeps only what finds the file on its own
/// volume: the path as mounted at /Volumes/<volume name> (folders above the volume get file ID 0), the file IDs on
/// the volume, and the volume's name, UUID, size, dates and properties. With those, the bookmark resolves wherever
/// the volume is mounted (checked by scripts/build-dmg.sh), by the volume's UUID.
///
/// Layout (little-endian), as the system writes it (version 0x10050000) and as documented by the mac_alias project:
/// "book", the total length, the version and the header's length (64), zero up to 64 bytes; then the data: the
/// table of contents' offset, items (length, type, value, padded to 4 bytes) and the table of contents (length,
/// 0xFFFFFFFE, id 1, next 0, count, then key/offset/0 entries sorted by key). Offsets count from the data's start.
func bookmarkRecord(for file: URL) throws -> Data {
    let location = try VolumeFile(file)
    let volume = URL(fileURLWithPath: location.mountPoint, isDirectory: true)
    let values = try volume.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeTotalCapacityKey])
    guard let uuid = values.volumeUUIDString, let size = values.volumeTotalCapacity else {
        throw Failure("cannot read the UUID and size of \(location.mountPoint)")
    }
    let ids = try location.ids()
    let above = location.recordedMountPoint.split(separator: "/").map(String.init)
    let path = above + location.relative.split(separator: "/").map(String.init)
    let fileIDs = Array(repeating: UInt64(0), count: above.count - 1) + [ids.root] + ids.below

    var data: [UInt8] = [0, 0, 0, 0]  // the table of contents' offset, filled in at the end
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data += $0 } }
    func padded() { while data.count % 4 != 0 { data.append(0) } }
    func item(_ type: UInt32, _ value: [UInt8]) -> UInt32 {
        let offset = UInt32(data.count)
        u32(UInt32(value.count))
        u32(type)
        data += value
        padded()
        return offset
    }
    func string(_ text: String) -> UInt32 { item(0x0101, Array(text.utf8)) }
    func number(_ value: UInt64) -> UInt32 { item(0x0304, withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
    func date(_ value: Date) -> UInt32 {
        item(0x0400, withUnsafeBytes(of: value.timeIntervalSinceReferenceDate.bitPattern.bigEndian) { Array($0) })
    }
    func flags(_ value: UInt64, known: UInt64) -> UInt32 {
        item(0x0201, [value, known, 0].flatMap { flag in withUnsafeBytes(of: flag.littleEndian) { Array($0) } })
    }
    func array(_ offsets: [UInt32]) -> UInt32 {
        item(0x0601, offsets.flatMap { offset in withUnsafeBytes(of: offset.littleEndian) { Array($0) } })
    }

    var contents: [(key: UInt32, offset: UInt32)] = []
    contents.append((0x1004, array(path.map(string))))  // path
    contents.append((0x1005, array(fileIDs.map(number))))  // file IDs along the path
    contents.append((0x1010, flags(0x1, known: 0xF)))  // a regular file
    contents.append((0x1040, date(location.fileCreated)))
    contents.append((0x2002, string(location.recordedMountPoint)))  // volume path
    contents.append((0x2005, item(0x0901, Array(("file://" + location.recordedMountPoint + "/").utf8))))  // volume URL
    contents.append((0x2010, string(location.volumeName)))
    contents.append((0x2011, string(uuid.uppercased())))
    contents.append((0x2012, number(UInt64(size))))
    contents.append((0x2013, date(location.volumeCreated)))
    // Local, ejectable, removable, a disk image, with persistent file IDs; out of the properties the system records.
    contents.append((0x2020, flags(0x1_0000_0261, known: 0x1_0000_13EF)))
    contents.sort { $0.key < $1.key }

    let tableOffset = UInt32(data.count)
    u32(UInt32(12 + 12 * contents.count))
    u32(0xFFFF_FFFE)
    u32(1)
    u32(0)
    u32(UInt32(contents.count))
    for entry in contents {
        u32(entry.key)
        u32(entry.offset)
        u32(0)
    }
    withUnsafeBytes(of: tableOffset.littleEndian) { data.replaceSubrange(0..<4, with: $0) }

    var header = Array("book".utf8)
    for value: UInt32 in [UInt32(64 + data.count), 0x1005_0000, 64] {
        withUnsafeBytes(of: value.littleEndian) { header += $0 }
    }
    header += [UInt8](repeating: 0, count: 64 - header.count)
    return Data(header + data)
}

// MARK: - Finder layout

func plist(_ object: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

func layoutRecords(volume: URL) throws -> [DSRecord] {
    let background = volume.appendingPathComponent(Window.backgroundFolder).appendingPathComponent(Window.backgroundFile)
    guard FileManager.default.fileExists(atPath: background.path) else { throw Failure("no background at \(background.path)") }
    for item in [Window.appName, Window.applicationsName] {
        // attributesOfItem does not follow symbolic links, so the Applications link counts as present.
        guard (try? FileManager.default.attributesOfItem(atPath: volume.appendingPathComponent(item).path)) != nil
        else { throw Failure("\(item) is missing from \(volume.path)") }
    }

    let origin = Window.screenOrigin
    let frame = Window.frameSize
    let windowSettings: [String: Any] = [
        "WindowBounds": "{{\(Int(origin.x)), \(Int(origin.y))}, {\(Int(frame.width)), \(Int(frame.height))}}",
        "ShowSidebar": false,
        "ContainerShowSidebar": false,
        "ShowToolbar": false,
        "ShowTabView": false,
        "ShowPathbar": false,
        "ShowStatusBar": false,
        "PreviewPaneVisibility": false,
        "SidebarWidth": 0,
    ]

    let backgroundColor = try loadPalette()["background"]!.components ?? [0, 0, 0, 1]
    let iconView: [String: Any] = [
        "viewOptionsVersion": 1,
        "arrangeBy": "none",
        "iconSize": Double(Window.iconSize),
        "textSize": Double(Window.labelTextSize),
        "labelOnBottom": true,
        "showItemInfo": false,
        "showIconPreview": true,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "backgroundType": 2,  // 2: a picture
        "backgroundColorRed": Double(backgroundColor[0]),
        "backgroundColorGreen": Double(backgroundColor[1]),
        "backgroundColorBlue": Double(backgroundColor[2]),
        "backgroundImageAlias": try aliasRecord(for: background),
    ]
    let bookmark = try bookmarkRecord(for: background)

    func position(_ point: CGPoint) -> Data {
        var bytes = Bytes()
        bytes.u32(UInt32(bitPattern: Int32(point.x)))
        bytes.u32(UInt32(bitPattern: Int32(point.y)))
        bytes.u32(0xFFFF_FFFF)
        bytes.u32(0xFFFF_0000)
        return bytes.data
    }

    // The hidden files that are on this volume, out of the window's way.
    var hiddenItems: [DSRecord] = []
    for (index, name) in Window.hiddenItems.enumerated()
    where (try? FileManager.default.attributesOfItem(atPath: volume.appendingPathComponent(name).path)) != nil {
        hiddenItems.append(DSRecord(name: name, code: "Iloc", value: .blob(position(Window.hiddenItemCenter(index)))))
    }

    return hiddenItems + [
        DSRecord(name: ".", code: "bwsp", value: .blob(try plist(windowSettings))),
        DSRecord(name: ".", code: "icvp", value: .blob(try plist(iconView))),
        DSRecord(name: ".", code: "pBBk", value: .blob(bookmark)),
        DSRecord(name: ".", code: "vSrn", value: .long(1)),
        DSRecord(name: ".", code: "vstl", value: .type("icnv")),  // open in icon view
        DSRecord(name: Window.appName, code: "Iloc", value: .blob(position(Window.appCenter))),
        DSRecord(name: Window.applicationsName, code: "Iloc", value: .blob(position(Window.applicationsCenter))),
    ]
}

/// Reading an alias record takes the deprecated Alias Manager bridge (there is no other). It is reached through
/// a protocol so the deprecation warning stays out of every build of this script.
protocol AliasReading { func bookmark(fromAlias alias: Data) -> Data? }
struct AliasReader: AliasReading {
    @available(macOS, deprecated: 11.0)
    func bookmark(fromAlias alias: Data) -> Data? {
        CFURLCreateBookmarkDataFromAliasRecord(nil, alias as CFData)?.takeRetainedValue() as Data?
    }
}

/// Where a bookmark points now, the way Finder would find it, or why it does not resolve.
func resolve(bookmark: Data) -> String {
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &stale) else { return "does not resolve" }
    return url.path
}

/// Whether an alias record, as aliasRecord(for:) writes it, describes the background on the volume at `root` the way
/// the Alias Manager identifies a file: by the volume's name and creation date, the IDs of the file and its folder,
/// its name, its path on the volume and the volume's usual mount point. macOS resolves an alias into any volume of
/// the same name mounted at /Volumes/<name>, so while another such volume is mounted, this is what tells a good
/// alias from a bad one.
func aliasCheck(_ alias: Data, root: URL) -> String {
    let bytes = [UInt8](alias)
    func u16(_ at: Int) -> Int { at + 2 <= bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : -1 }
    func u32(_ at: Int) -> UInt32? {
        at + 4 <= bytes.count ? bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) } : nil
    }
    func pascal(_ at: Int) -> String? {
        guard at < bytes.count, at + 1 + Int(bytes[at]) <= bytes.count else { return nil }
        return String(decoding: bytes[(at + 1)..<(at + 1 + Int(bytes[at]))], as: UTF8.self)
    }
    guard bytes.count >= 150, u16(6) == 2 else { return "is not a version 2 alias record" }
    var tags: [Int: String] = [:]
    var at = 150
    while at + 4 <= bytes.count {
        let tag = Int(Int16(truncatingIfNeeded: u16(at)))
        let length = u16(at + 2)
        if tag == -1 { break }
        guard at + 4 + length <= bytes.count else { return "has a broken tag \(tag)" }
        tags[tag] = String(decoding: bytes[(at + 4)..<(at + 4 + length)], as: UTF8.self)
        at += 4 + length + length % 2
    }
    let background = root.appendingPathComponent(Window.backgroundFolder).appendingPathComponent(Window.backgroundFile)
    var folderInfo = stat()
    var fileInfo = stat()
    guard let location = try? VolumeFile(background), stat(background.deletingLastPathComponent().path, &folderInfo) == 0,
          stat(background.path, &fileInfo) == 0 else { return "cannot be checked: the volume has no background" }
    var problems: [String] = []
    if pascal(10) != location.volumeName.replacingOccurrences(of: ":", with: "/") { problems.append("volume name") }
    if u32(38) != UInt32(location.volumeCreated.timeIntervalSince1970 + 2_082_844_800) {
        problems.append("volume creation date")
    }
    if u32(46) != UInt32(truncatingIfNeeded: folderInfo.st_ino) { problems.append("folder ID") }
    if pascal(50) != Window.backgroundFile { problems.append("file name") }
    if u32(114) != UInt32(truncatingIfNeeded: fileInfo.st_ino) { problems.append("file ID") }
    if tags[18] != "/" + location.relative { problems.append("path") }
    if tags[19] != location.recordedMountPoint { problems.append("mount point") }
    return problems.isEmpty ? "matches this volume" : "does not match this volume (\(problems.joined(separator: ", ")))"
}

/// One line per record. The background's bookmark (`pBBk`) and alias (`icvp`) are resolved, so a check run on
/// a mounted DMG shows whether Finder will find the picture; resolved paths print as `-> <path>`. The alias is also
/// checked field by field against the volume at `root`, the folder holding the .DS_Store.
func describe(_ record: DSRecord, root: URL) -> String {
    let value: String
    switch record.value {
    case .long(let number): value = "long \(number)"
    case .bool(let flag): value = "bool \(flag)"
    case .type(let code): value = "type \(code)"
    case .ustr(let string): value = "ustr \(string)"
    case .blob(let data):
        if record.code == "Iloc", data.count >= 8 {
            var reader = Reader(data: data, offset: 0)
            let x = (try? reader.u32()) ?? 0
            let y = (try? reader.u32()) ?? 0
            value = "position \(Int32(bitPattern: x)), \(Int32(bitPattern: y))"
        } else if data.starts(with: Data("bplist".utf8)),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            var fields = object.keys.sorted().map { key in
                let item = object[key]!
                if let data = item as? Data { return "\(key)=<\(data.count) bytes>" }
                return "\(key)=\(item)"
            }
            if let alias = object["backgroundImageAlias"] as? Data {
                let bookmark = (AliasReader() as AliasReading).bookmark(fromAlias: alias)
                fields.insert("backgroundImageAlias -> " + (bookmark.map(resolve(bookmark:)) ?? "unreadable"), at: 0)
                fields.insert("backgroundImageAlias " + aliasCheck(alias, root: root), at: 1)
            }
            value = fields.joined(separator: " ")
        } else if data.starts(with: Data("book".utf8)) {
            value = "bookmark -> \(resolve(bookmark: data))"
        } else {
            value = "blob <\(data.count) bytes>"
        }
    }
    return "\(record.name)\t\(record.code)\t\(value)"
}

/// What is wrong with a layout's window size and icon positions next to what `Window` describes; empty when it is
/// right. `root` is the folder holding the .DS_Store, which says which hidden files are on the volume.
func layoutProblems(_ records: [DSRecord], root: URL) -> [String] {
    var problems: [String] = []
    func record(_ name: String, _ code: String) -> DSRecord? { records.first { $0.name == name && $0.code == code } }
    func position(of name: String) -> CGPoint? {
        guard let record = record(name, "Iloc"), case .blob(let data) = record.value else { return nil }
        var reader = Reader(data: data, offset: 0)
        guard let x = try? reader.u32(), let y = try? reader.u32() else { return nil }
        return CGPoint(x: Int(Int32(bitPattern: x)), y: Int(Int32(bitPattern: y)))
    }

    if let settings = record(".", "bwsp"), case .blob(let data) = settings.value,
       let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let bounds = object["WindowBounds"] as? String {
        let numbers = bounds.split(whereSeparator: { !"0123456789-".contains($0) }).compactMap { Int($0) }
        let expected = Window.frameSize
        if numbers.count != 4 || CGFloat(numbers[2]) != expected.width || CGFloat(numbers[3]) != expected.height {
            problems.append("the window is \(bounds), not \(Int(expected.width)) x \(Int(expected.height)) pt "
                            + "(\(Int(Window.size.height)) pt of artwork, a title bar and room for Finder's bars)")
        }
        for key in ["ShowToolbar", "ShowSidebar"] where (object[key] as? Bool) != false {
            problems.append("\(key) is not off")
        }
    } else {
        problems.append("there are no window settings")
    }

    for (name, center) in [(Window.appName, Window.appCenter), (Window.applicationsName, Window.applicationsCenter)] {
        if let found = position(of: name) {
            if found != center { problems.append("\(name) sits at \(Int(found.x)), \(Int(found.y)), not \(Int(center.x)), \(Int(center.y))") }
        } else {
            problems.append("\(name) has no position")
        }
    }

    // A hidden file with no position lands in a free grid slot, over the artwork, in a Finder that shows hidden
    // files; one inside the window does the same.
    let half = Window.iconSize / 2
    for name in Window.hiddenItems where FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
        guard let found = position(of: name) else {
            problems.append("\(name) has no position, so a Finder that shows hidden files puts it over the artwork")
            continue
        }
        if found.x - half < Window.frameSize.width && found.y - half < Window.frameSize.height {
            problems.append("\(name) sits at \(Int(found.x)), \(Int(found.y)), inside the window")
        }
    }
    return problems
}

// MARK: - Command line

var arguments = Array(CommandLine.arguments.dropFirst().filter { $0 != "--dev" })
let usage = """
    usage: dmg-window.swift background <outputDirectory> [--version <x.y.z>] [--preview <file.png>] [--dev]
           dmg-window.swift ds-store <volumeRoot> [--dev]
           dmg-window.swift dump <path/to/.DS_Store> [--dev]
    """

do {
    guard let command = arguments.first else { fail(usage) }
    arguments.removeFirst()
    switch command {
    case "background":
        guard let output = arguments.first else { fail(usage) }
        arguments.removeFirst()
        var version: String?
        var preview: URL?
        while let option = arguments.first {
            arguments.removeFirst()
            guard let value = arguments.first else { fail("\(option) needs a value") }
            arguments.removeFirst()
            switch option {
            case "--version": version = value
            case "--preview": preview = URL(fileURLWithPath: value)
            default: fail("unknown option \(option)\n\(usage)")
            }
        }
        try generateBackground(outputDirectory: URL(fileURLWithPath: output, isDirectory: true),
                               version: version, preview: preview)
    case "ds-store":
        guard arguments.count == 1 else { fail(usage) }
        let volume = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
        let file = try DSStore.encode(try layoutRecords(volume: volume))
        let destination = volume.appendingPathComponent(".DS_Store")
        try file.write(to: destination)
        print("wrote \(destination.path) (\(file.count) bytes)")
    case "dump":
        guard arguments.count == 1 else { fail(usage) }
        let file = URL(fileURLWithPath: arguments[0])
        let records = try DSStore.decode(try Data(contentsOf: file))
        let root = file.deletingLastPathComponent()
        for record in records { print(describe(record, root: root)) }
        let problems = layoutProblems(records, root: root)
        print(problems.isEmpty ? "layout ok" : problems.map { "layout problem: \($0)" }.joined(separator: "\n"))
    case "-h", "--help":
        print(usage)
    default:
        fail("unknown command \(command)\n\(usage)")
    }
} catch {
    fail("\(error)")
}
