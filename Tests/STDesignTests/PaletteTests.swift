import AppKit
import SwiftUI
import Testing
@testable import STDesign

/// Contrast figures from spec section 3.3, rounded to one decimal, against the lowest of
/// `background`, `surface` and `raised`.
private let specFigures: [(name: String, hex: String, figure: Double)] = [
    ("ink", STPalette.ink, 15.1),
    ("inkSecondary", STPalette.inkSecondary, 8.4),
    ("inkTertiary", STPalette.inkTertiary, 5.7),
    ("gold", STPalette.gold, 8.3),
    ("goldStroke", STPalette.goldStroke, 6.7),
    ("stroke", STPalette.stroke, 3.0),
    ("danger", STPalette.danger, 5.9),
    ("success", STPalette.success, 8.0),
]

private let grounds = [STPalette.background, STPalette.surface, STPalette.raised]

private func minimumContrast(_ hex: String) -> Double {
    grounds.map { STPalette.contrastRatio(hex, $0) }.min() ?? 0
}

@Test(arguments: specFigures)
func tokenMeetsSpecContrastFigure(token: (name: String, hex: String, figure: Double)) {
    let lowest = minimumContrast(token.hex)
    // Spec figures are rounded to the nearest tenth, so the true value may sit up to 0.05 below.
    #expect(lowest >= token.figure - 0.05, "\(token.name) lowest contrast \(lowest) is below \(token.figure)")
    #expect((lowest * 10).rounded() / 10 == token.figure, "\(token.name) rounds to \((lowest * 10).rounded() / 10), spec says \(token.figure)")
}

@Test(arguments: [STPalette.ink, STPalette.inkSecondary, STPalette.inkTertiary, STPalette.gold, STPalette.danger, STPalette.success])
func textTokensMeetAA(hex: String) {
    for ground in grounds {
        #expect(STPalette.contrastRatio(hex, ground) >= 4.5)
    }
}

@Test(arguments: [STPalette.goldStroke, STPalette.stroke])
func nonTextTokensMeetThreeToOne(hex: String) {
    for ground in grounds {
        #expect(STPalette.contrastRatio(hex, ground) >= 3.0)
    }
}

@Test func contrastRatioIsSymmetricAndBounded() {
    #expect(STPalette.contrastRatio("#000000", "#FFFFFF") > 20.99)
    #expect(STPalette.contrastRatio("#000000", "#FFFFFF") < 21.01)
    #expect(STPalette.contrastRatio("#336699", "#336699") == 1)
    #expect(STPalette.contrastRatio(STPalette.ink, STPalette.background) == STPalette.contrastRatio(STPalette.background, STPalette.ink))
}

@Test func backgroundIsTheDarkestGround() {
    #expect(STPalette.contrastRatio(STPalette.ink, STPalette.background) > STPalette.contrastRatio(STPalette.ink, STPalette.surface))
    #expect(STPalette.contrastRatio(STPalette.ink, STPalette.surface) > STPalette.contrastRatio(STPalette.ink, STPalette.raised))
}

private func srgbChannels(_ color: Color) -> [Int] {
    guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return [] }
    return [converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent]
        .map { Int(($0 * 255).rounded()) }
}

@Test func hexParsesChannels() {
    #expect(srgbChannels(Color(hex: "#D9AE52")) == [0xD9, 0xAE, 0x52, 255])
    #expect(srgbChannels(Color(hex: "#0B0A09")) == [0x0B, 0x0A, 0x09, 255])
    #expect(srgbChannels(Color(hex: "#ffffff")) == [255, 255, 255, 255])
}

@Test(arguments: ["", "#", "D9AE52", "#D9AE5", "#D9AE521", "#GGGGGG", "#12 456", "#+12345", "not a color"])
func invalidHexYieldsBlack(hex: String) {
    #expect(srgbChannels(Color(hex: hex)) == [0, 0, 0, 255])
}

@Test func colorTokensMatchPaletteHex() {
    #expect(srgbChannels(STColor.ink) == [0xF4, 0xEF, 0xE6, 255])
    #expect(srgbChannels(STColor.background) == [0x0B, 0x0A, 0x09, 255])
    #expect(srgbChannels(STColor.goldStroke) == [0xC8, 0x9A, 0x3A, 255])
    #expect(srgbChannels(STColor.rule) == [0x2E, 0x29, 0x24, 255])
}

@Test func paletteHexParsingIsStrict() {
    #expect(STPalette.rgb("#0B0A09")?.red == 0x0B)
    #expect(STPalette.rgb("#0b0a09")?.blue == 0x09)
    #expect(STPalette.rgb("0B0A09") == nil)
    #expect(STPalette.rgb("#0B0A0") == nil)
    #expect(STPalette.rgb("#0B0A0Z") == nil)
}
