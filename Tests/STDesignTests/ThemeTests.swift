import SwiftUI
import AppKit
import Testing
@testable import STDesign

private func contrast(_ hex: String, _ ground: String = STPalette.background) -> Double {
    STPalette.contrastRatio(hex, ground)
}

@MainActor
@Test func textScaleIsClamped() {
    let theme = STTheme()
    theme.textScale = 5
    #expect(theme.textScale == 1.3)
    theme.textScale = 0.1
    #expect(theme.textScale == 0.9)
    theme.textScale = 1.1
    #expect(theme.textScale == 1.1)
    theme.textScale = .nan
    #expect(theme.textScale == 1.0)
    #expect(STTheme(textScale: 9).textScale == 1.3)
}

@MainActor
@Test func soundVolumeIsClamped() {
    let theme = STTheme()
    theme.soundVolume = 3
    #expect(theme.soundVolume == 1)
    theme.soundVolume = -1
    #expect(theme.soundVolume == 0)
    theme.soundVolume = 0.25
    #expect(theme.soundVolume == 0.25)
    theme.soundVolume = .nan
    #expect(theme.soundVolume == 0.7)
    #expect(STTheme(soundVolume: -4).soundVolume == 0)
}

@Test(arguments: ["", "gold", "#12345", "#GGGGGG", "D9AE52", "#D9AE5200", "🙂"])
func invalidAccentFallsBackToGold(hex: String) {
    #expect(STTheme.sanitizedAccent(hex) == STPalette.gold)
}

@Test func validAccentIsNormalizedToUppercase() {
    #expect(STTheme.sanitizedAccent("#7dbf86") == "#7DBF86")
    #expect(STTheme.sanitizedAccent(STPalette.gold) == STPalette.gold)
}

@Test(arguments: ["#000000", "#220000", "#1A2B4C", "#333333", "#003366", "#4B0082", "#0B0A09", "#6E655B", "#801010"])
func darkAccentsAreLightenedToAA(hex: String) {
    let result = STTheme.sanitizedAccent(hex)
    #expect(contrast(result) >= 4.5)
    #expect(STPalette.rgb(result) != nil)
    #expect(result != hex)
}

@Test(arguments: ["#FFFFFF", "#7DBF86", "#E07A6E", "#D9AE52", "#80C0FF"])
func accessibleAccentsAreUnchanged(hex: String) {
    #expect(STTheme.sanitizedAccent(hex) == hex)
}

@Test func lighteningStaysCloseToTheChosenHue() {
    let result = STTheme.sanitizedAccent("#1A2B4C")
    let (r, g, b) = (STPalette.rgb(result)!.red, STPalette.rgb(result)!.green, STPalette.rgb(result)!.blue)
    #expect(b > g && g > r)
}

@MainActor
@Test func accentHexIsSanitizedWheneverSet() {
    let theme = STTheme(accentHex: "nonsense")
    #expect(theme.accentHex == STPalette.gold)
    theme.accentHex = "#000000"
    #expect(contrast(theme.accentHex) >= 4.5)
    theme.accentHex = "#80c0ff"
    #expect(theme.accentHex == "#80C0FF")
    theme.accentHex = "bad"
    #expect(theme.accentHex == STPalette.gold)
}

@Test func defaultGoldUsesGoldStroke() {
    #expect(STTheme.strokeHex(forAccent: STPalette.gold) == STPalette.goldStroke)
}

@Test(arguments: ["#80C0FF", "#7DBF86", "#E07A6E", "#FFFFFF", "#000000", "#4B0082", "#C0C0C0", "#FFD700"])
func accentStrokeKeepsThreeToOne(accent: String) {
    let sanitized = STTheme.sanitizedAccent(accent)
    let stroke = STTheme.strokeHex(forAccent: sanitized)
    for ground in [STPalette.background, STPalette.surface, STPalette.raised] {
        #expect(contrast(stroke, ground) >= 3.0, "\(accent) -> \(stroke) vs \(ground)")
    }
}

@Test func accentStrokeLeansTowardBackground() {
    let accent = "#FFFFFF"
    let stroke = STTheme.strokeHex(forAccent: accent)
    #expect(stroke != accent)
    #expect(contrast(stroke) < contrast(accent))
}

@MainActor
@Test func themeAccentStrokeFollowsAccent() {
    let theme = STTheme()
    #expect(channels(theme.accentStroke) == channels(STColor.goldStroke))
    theme.accentHex = "#80C0FF"
    #expect(channels(theme.accentStroke) != channels(STColor.goldStroke))
    #expect(channels(theme.accent) == [0x80, 0xC0, 0xFF])
}

private func channels(_ color: Color) -> [Int] {
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return [] }
    return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
}

@MainActor
@Test func increaseContrastPromotesSecondaryColorsToInk() {
    let theme = STTheme()
    #expect(channels(theme.inkSecondary) == channels(STColor.inkSecondary))
    #expect(channels(theme.inkTertiary) == channels(STColor.inkTertiary))
    #expect(channels(theme.stroke) == channels(STColor.stroke))
    theme.increaseContrast = true
    #expect(channels(theme.inkSecondary) == channels(STColor.ink))
    #expect(channels(theme.inkTertiary) == channels(STColor.ink))
    #expect(channels(theme.stroke) == channels(STColor.ink))
}

@MainActor
@Test func reduceMotionFollowsModeOrSystem() {
    let theme = STTheme()
    #expect(!theme.reduceMotion)
    theme.motionMode = .reduced
    #expect(theme.reduceMotion)
    theme.motionMode = .full
    theme.systemReduceMotion = true
    #expect(theme.reduceMotion)
}

@MainActor
@Test func environmentDefaultsAreSafeToRead() {
    let values = EnvironmentValues()
    #expect(values.stTheme === STTheme.fallback)
    #expect(values.stTheme.textScale == 1.0)
    #expect(values.stSoundPlayer === STSoundPlayer.silent)
}
