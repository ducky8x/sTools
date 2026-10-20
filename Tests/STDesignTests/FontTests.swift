import AppKit
import CoreText
import CryptoKit
import SwiftUI
import Testing
@testable import STDesign

@Test func typographyTableMatchesSpec() {
    typealias Row = (STTextStyle, CGFloat, CGFloat, CGFloat)
    let table: [Row] = [
        (.wordmark, 72, 76, -0.01),
        (.pageTitle, 40, 44, 0),
        (.sectionTitle, 22, 28, 0),
        (.sidebarName, 18, 22, 0),
        (.standfirst, 16, 22, 0),
        (.body, 14, 20, 0),
        (.label, 12, 16, 0.04),
        (.caption, 12, 16, 0),
    ]
    #expect(table.count == STTextStyle.allCases.count)
    for (style, size, line, tracking) in table {
        let metrics = style.metrics
        #expect(metrics.size == size, "\(style) size")
        #expect(metrics.lineHeight == line, "\(style) line height")
        #expect(metrics.tracking == tracking, "\(style) tracking")
    }
}

@Test func scaledMetricsMultiplyEverythingButEm() {
    let scaled = STTextStyle.label.metrics.scaled(by: 1.25)
    #expect(scaled.size == 15)
    #expect(scaled.lineHeight == 20)
    #expect(scaled.tracking == 0.04)
    #expect(scaled.trackingPoints == 0.04 * 15)
    #expect(STTextStyle.wordmark.metrics.trackingPoints == -0.72)
}

@Test func registerMakesBundledFontsResolvable() {
    #expect(STFont.register())
    #expect(STFont.register(), "registering twice must still report success")
    #expect(NSFont(name: "DMSerifDisplay-Regular", size: 20) != nil)
    #expect(NSFont(name: "DMSerifDisplay-Italic", size: 20) != nil)
    #expect(NSFont(name: "BodoniModa-Regular", size: 20) != nil)
    #expect(NSFont(name: "SourceSerif4Roman-Regular", size: 20) != nil)
}

@Test func registeredFontsAreDMSerifDisplay() throws {
    #expect(STFont.register())
    let regular = try #require(NSFont(name: "DMSerifDisplay-Regular", size: 20))
    let italic = try #require(NSFont(name: "DMSerifDisplay-Italic", size: 20))
    #expect(regular.familyName == "DM Serif Display")
    #expect(italic.fontDescriptor.symbolicTraits.contains(.italic))
}

@Test func registeredFontsIncludeBodoniModaAndSourceSerif4() throws {
    #expect(STFont.register())
    let bodoni = try #require(NSFont(name: "BodoniModa-Regular", size: 20))
    let sourceSerif = try #require(NSFont(name: "SourceSerif4Roman-SemiBold", size: 20))
    #expect(bodoni.familyName == "Bodoni Moda")
    #expect(sourceSerif.familyName == "Source Serif 4")
}

private func sha256(ofResource name: String, ext: String) throws -> String {
    let url = try #require(STFont.resourceURL(name, ext))
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
}

@Test func fontFilesMatchPinnedChecksums() throws {
    #expect(try sha256(ofResource: "DMSerifDisplay-Regular", ext: "ttf") == "8cc3643535edf039aa5d95440a8542735e9197e4f4b8d9303e980fefbf5ab616")
    #expect(try sha256(ofResource: "DMSerifDisplay-Italic", ext: "ttf") == "df74c0ac387baeaeb0fe4f2324e1668e6a3ed8c09cd9796fe162c71753e19e45")
    #expect(try sha256(ofResource: "BodoniModa[opsz,wght]", ext: "ttf") == "550f5e34ee0a828d7941b1fe9bc58b34e5260d3f33a61532e6d0a0114e79a5cf")
    #expect(try sha256(ofResource: "SourceSerif4[opsz,wght]", ext: "ttf") == "97b2d4da6e3cb494b5a1e66ae176914d852ccabef49e0c02c0df25f3e39aca0b")
    #expect(try sha256(ofResource: "OFL", ext: "txt") == "d7d1ba3c6924303e286d6933fa9992096a89872749d373c649667adb939dc190")
}

@Test func licenseShipsInTheBundle() throws {
    let url = try #require(STFont.resourceURL("OFL", "txt"))
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("SIL OPEN FONT LICENSE"))
}

// MARK: Small caps probe (spec 3.2 / section 10: "verified in M0")

private func newYorkSemibold(_ size: CGFloat, smallCaps: Bool) throws -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    var descriptor = try #require(base.fontDescriptor.withDesign(.serif))
    if smallCaps {
        let feature: [NSFontDescriptor.FeatureKey: Int] = [
            .typeIdentifier: kLowerCaseType,
            .selectorIdentifier: kLowerCaseSmallCapsSelector,
        ]
        descriptor = descriptor.addingAttributes([.featureSettings: [feature]])
    }
    return try #require(NSFont(descriptor: descriptor, size: size))
}

private func glyphs(_ font: NSFont, _ text: String) -> [CGGlyph] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    var result: [CGGlyph] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        var runGlyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(), &runGlyphs)
        result += runGlyphs
    }
    return result
}

@Test func newYorkOffersRealSmallCapsAtTheFontLevel() throws {
    let plain = try newYorkSemibold(12, smallCaps: false)
    let small = try newYorkSemibold(12, smallCaps: true)
    let features = (CTFontCopyFeatures(plain as CTFont) as? [[String: Any]]) ?? []
    let caseFeature = features.first { ($0["CTFeatureTypeIdentifier"] as? Int) == kLowerCaseType }
    let selectors = (caseFeature?["CTFeatureTypeSelectors"] as? [[String: Any]]) ?? []
    #expect(selectors.contains { ($0["CTFeatureSelectorIdentifier"] as? Int) == kLowerCaseSmallCapsSelector })
    #expect(glyphs(plain, "abc") != glyphs(small, "abc"), "small caps must substitute dedicated glyphs")
}

@MainActor
private func ink(_ view: some View) -> (height: Int, width: Int, pixels: [UInt8]) {
    let renderer = ImageRenderer(content: view.padding(4).background(Color.white).environment(\.colorScheme, .light))
    renderer.scale = 4
    guard let image = renderer.cgImage else { return (0, 0, []) }
    let (width, height) = (image.width, image.height)
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return (0, 0, []) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var rows = Set<Int>(), columns = Set<Int>()
    for y in 0..<height { for x in 0..<width where pixels[y * width + x] < 128 { rows.insert(y); columns.insert(x) } }
    guard let (top, bottom) = rows.min().flatMap({ low in rows.max().map { (low, $0) } }),
          let (left, right) = columns.min().flatMap({ low in columns.max().map { (low, $0) } }) else { return (0, 0, pixels) }
    return (bottom - top + 1, right - left + 1, pixels)
}

/// Pins the outcome of the M0 probe: SwiftUI's `Font.smallCaps()` really switches New York to its
/// small-capital glyphs on this machine. Source Serif 4 (the font `STFont.label()` uses now) ships the
/// same lower/upper-case small-caps OpenType features, confirmed by `swiftUISmallCapsRenderRealSmallCapitals`.
@MainActor
@Test func swiftUISmallCapsRenderRealSmallCapitals() {
    #expect(STFont.register())
    let plain = Font.custom("SourceSerif4Roman-SemiBold", size: 12)
    let plainLower = ink(Text("abc").font(plain))
    let labelLower = ink(Text("abc").font(STFont.label()))
    let labelUpper = ink(Text("ABC").font(STFont.label()))
    #expect(plainLower.height > 0 && labelLower.height > 0)
    #expect(labelLower.height < plainLower.height, "small caps are shorter than the plain lowercase ascender")
    #expect(labelLower.pixels != plainLower.pixels)
    // Anti-aliasing can differ by a few pixels when other tests render at the same time, so compare size
    // exactly and the pixels with a tolerance.
    #expect(labelLower.height == labelUpper.height && labelLower.width == labelUpper.width,
            "capitals and lowercase both render as small capitals")
    let differing = zip(labelLower.pixels, labelUpper.pixels).filter { abs(Int($0) - Int($1)) > 64 }.count
    #expect(differing * 100 < labelLower.pixels.count, "capitals and lowercase look the same as small capitals")
}
