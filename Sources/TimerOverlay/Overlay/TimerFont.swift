import AppKit
import CoreText
import STDesign

/// The overlay's typeface (spec 5.6.4, Timer round D2): Source Serif 4 semibold with tabular (fixed-width) figures,
/// so the plate never shifts as the seconds change. Advanced offers New York, SF Pro and Bodoni Moda by name, and any
/// family installed on the Mac; a family that isn't there any more falls back to Source Serif 4.
@MainActor
public enum TimerFont {
    public static let sourceSerif4 = "Source Serif 4"
    public static let newYork = "New York"
    public static let sfPro = "SF Pro"
    public static let bodoniModa = "Bodoni Moda"

    /// The families the page offers by name, in its order (spec 5.6.7). The first is the default.
    public static let offeredFamilies = [sourceSerif4, newYork, sfPro, bodoniModa]

    /// NSFontManager's weight for semibold, on its 0-15 scale (5 is regular, 9 bold).
    static let semiboldWeight = 8

    /// Whether `family` can be drawn: one of the offered families, or a family installed on this Mac.
    public static func isAvailable(_ family: String) -> Bool {
        baseFont(family: family, size: 12) != nil
    }

    /// The family the overlay is drawn in: `family`, or Source Serif 4 when it can't be drawn.
    public static func resolvedFamily(_ family: String) -> String {
        isAvailable(family) ? family : sourceSerif4
    }

    /// The digits' font: `family` at `size` points, semibold where the family has it, asking for tabular figures
    /// (fonts without them keep their own).
    public static func digits(family: String, size: CGFloat) -> NSFont {
        let base = baseFont(family: family, size: size) ?? fallback(size: size)
        return adding([(kNumberSpacingType, kMonospacedNumbersSelector)], to: base)
    }

    /// The label's and the *Paused* mark's font: the digits' family, semibold, in small capitals like sTools'
    /// own labels.
    public static func caption(family: String, size: CGFloat) -> NSFont {
        let base = baseFont(family: family, size: size) ?? fallback(size: size)
        return adding([(kLowerCaseType, kLowerCaseSmallCapsSelector), (kUpperCaseType, kUpperCaseSmallCapsSelector)], to: base)
    }

    /// The installed families a font picker lists after the offered ones: without those, without hidden system
    /// families, sorted as Finder sorts.
    public static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") && !offeredFamilies.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Private

    /// The bundled fonts, registered once before the first lookup. The app registers them at launch too.
    private static let registered: Bool = STFont.register()

    private static func baseFont(family: String, size: CGFloat) -> NSFont? {
        _ = registered
        switch family {
        case newYork:
            let system = NSFont.systemFont(ofSize: size, weight: .semibold)
            return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
        case sfPro:
            return NSFont.systemFont(ofSize: size, weight: .semibold)
        default:
            guard !family.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: semiboldWeight, size: size)
        }
    }

    /// Source Serif 4 semibold, or the system serif if the bundled font is somehow missing.
    private static func fallback(size: CGFloat) -> NSFont {
        baseFont(family: sourceSerif4, size: size)
            ?? baseFont(family: newYork, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private static func adding(_ features: [(type: Int, selector: Int)], to font: NSFont) -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = features.map {
            [.typeIdentifier: $0.type, .selectorIdentifier: $0.selector]
        }
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
