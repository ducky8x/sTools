import AppKit
import CoreText
import STDesign
import Testing
@testable import TimerOverlay

/// How wide `text` is set in `font`.
@MainActor
private func width(_ text: String, _ font: NSFont) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: font]).size().width
}

/// The font features `font` asks for, as (type, selector) pairs.
private func features(_ font: NSFont) -> [(type: Int, selector: Int)] {
    let settings = font.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Any]] ?? []
    return settings.compactMap { setting in
        guard let type = setting[.typeIdentifier] as? Int, let selector = setting[.selectorIdentifier] as? Int else { return nil }
        return (type, selector)
    }
}

@Suite("Timer font")
@MainActor
struct TimerFontTests {
    init() { STFont.register() }

    @Test func theOfferedFamiliesAreTheSpecsFour() {
        #expect(TimerFont.offeredFamilies == ["Source Serif 4", "New York", "SF Pro", "Bodoni Moda"])
        #expect(TimerFont.offeredFamilies.first == TimerOverlaySettings.defaultFontFamily)
    }

    @Test(arguments: ["Source Serif 4", "New York", "SF Pro", "Bodoni Moda"])
    func everyOfferedFamilyIsAvailable(family: String) {
        #expect(TimerFont.isAvailable(family))
        #expect(TimerFont.resolvedFamily(family) == family)
    }

    @Test func sourceSerif4IsSemibold() {
        let font = TimerFont.digits(family: "Source Serif 4", size: 40)
        #expect(font.fontName == "SourceSerif4Roman-SemiBold")
        #expect(font.pointSize == 40)
    }

    @Test func bodoniModaIsItsSemibold() {
        #expect(TimerFont.digits(family: "Bodoni Moda", size: 40).fontName.contains("SemiBold"))
    }

    @Test func newYorkIsTheSystemSerif() {
        let font = TimerFont.digits(family: "New York", size: 40)
        #expect(font.fontName.contains("NewYork"))
    }

    @Test func sfProIsTheSystemFont() {
        let font = TimerFont.digits(family: "SF Pro", size: 40)
        #expect(font.familyName == NSFont.systemFont(ofSize: 40).familyName)
        #expect(font.pointSize == 40)
    }

    @Test func anyInstalledFamilyWorks() {
        #expect(TimerFont.isAvailable("Helvetica Neue"))
        #expect(TimerFont.digits(family: "Helvetica Neue", size: 30).familyName == "Helvetica Neue")
    }

    @Test(arguments: ["No Such Family 12345", "", "   "])
    func aMissingFamilyFallsBackToSourceSerif4(family: String) {
        #expect(!TimerFont.isAvailable(family))
        #expect(TimerFont.resolvedFamily(family) == "Source Serif 4")
        #expect(TimerFont.digits(family: family, size: 40).fontName == "SourceSerif4Roman-SemiBold")
        #expect(TimerFont.caption(family: family, size: 12).familyName == TimerFont.digits(family: family, size: 12).familyName)
    }

    /// Fixed-width figures, so the plate never shifts as the seconds change (spec 5.6.4).
    @Test(arguments: ["Source Serif 4", "New York", "SF Pro", "Bodoni Moda", "No Such Family 12345"])
    func theDigitsAreTabular(family: String) {
        let font = TimerFont.digits(family: family, size: 40)
        let zeros = width("00:00", font)
        #expect(abs(width("11:11", font) - zeros) < 0.01)
        #expect(abs(width("47:59", font) - zeros) < 0.01)
        #expect(abs(width("1:08:23", font) - width("9:59:59", font)) < 0.01)
    }

    @Test func theDigitsAskForTabularFigures() {
        let asked = features(TimerFont.digits(family: "Source Serif 4", size: 40))
        #expect(asked.contains { $0.type == kNumberSpacingType && $0.selector == kMonospacedNumbersSelector })
    }

    /// Georgia has only proportional figures: it still draws, in its own figures ("tabular where it has them").
    @Test func aFamilyWithoutTabularFiguresKeepsItsOwn() {
        let font = TimerFont.digits(family: "Georgia", size: 40)
        #expect(font.familyName == "Georgia")
        #expect(width("00:00", font) != width("11:11", font))
    }

    @Test(arguments: ["Source Serif 4", "New York", "Bodoni Moda"])
    func theCaptionIsTheSameFamilyInSmallCapitals(family: String) {
        let caption = TimerFont.caption(family: family, size: 12)
        #expect(caption.familyName == TimerFont.digits(family: family, size: 12).familyName)
        #expect(caption.pointSize == 12)
        let asked = features(caption)
        #expect(asked.contains { $0.type == kLowerCaseType && $0.selector == kLowerCaseSmallCapsSelector })
        #expect(asked.contains { $0.type == kUpperCaseType && $0.selector == kUpperCaseSmallCapsSelector })
    }

    @Test func installedFamiliesLeaveOutTheOfferedAndHiddenOnes() {
        let installed = TimerFont.installedFamilies()
        #expect(installed.contains("Helvetica Neue"))
        #expect(!installed.contains { TimerFont.offeredFamilies.contains($0) })
        #expect(!installed.contains { $0.hasPrefix(".") })
        #expect(installed == installed.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
