import AppKit
import CoreText
import SwiftUI

/// Two Serifs: Bodoni Moda for display text (wordmark, page/section titles, sidebar tool names),
/// Source Serif 4 for everything else (body, labels, figures). Bodoni Moda is held at its thinnest
/// weight with optical size pushed to its display maximum — see `bodoniModaDisplay(_:)`.
public enum STFont {
    public static func display(_ size: CGFloat) -> Font { bodoniModaDisplay(size) }
    public static func displayItalic(_ size: CGFloat) -> Font { bodoniModaDisplay(size).italic() }
    public static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .custom(sourceSerifName(weight), size: size) }
    public static func textItalic(_ size: CGFloat) -> Font { .custom(sourceSerifName(.regular), size: size).italic() }

    /// Source Serif 4 semibold with real small capitals (confirmed: Source Serif 4 ships dedicated
    /// lower/upper-case small-cap glyphs, the same OpenType features New York used). Tracking (+4%) is
    /// added by `stStyle(.label)`, because a `Font` cannot carry it.
    public static func label() -> Font { label(scale: 1) }

    /// `label()` at a text-size multiplier (12 pt base).
    public static func label(scale: Double) -> Font {
        .custom(sourceSerifName(.semibold), size: STTextStyle.label.metrics.size * scale).smallCaps()
    }

    public static func figures(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        text(size, weight: weight).monospacedDigit()
    }

    /// The height a SwiftUI `TextField` in `text(size, weight:)` or `figures(size, weight:)` (its digits don't
    /// change it) needs for its line: the height its AppKit field sizes its cell to, `NSLayoutManager`'s default
    /// line height. The field gets the font at the nearest whole point size (12.6 pt is drawn at 13 pt), so the
    /// line is measured at that size.
    @MainActor
    public static func textLineHeight(_ size: CGFloat, weight: Font.Weight = .regular) -> CGFloat {
        let points = size.rounded()
        let font = NSFont(name: sourceSerifName(weight), size: points) ?? .systemFont(ofSize: points)
        return lineMeasurer.defaultLineHeight(for: font)
    }

    @MainActor private static let lineMeasurer = NSLayoutManager()

    /// DM Serif Display, which the spec keeps for the wordmark in the Prologue's greeting.
    public static func greetingWordmark(_ size: CGFloat) -> Font { .custom(displayRegularName, size: size) }

    static let displayRegularName = "DMSerifDisplay-Regular"
    static let displayItalicName = "DMSerifDisplay-Italic"

    /// A bundled file under `Resources/Fonts` (the folder SwiftPM copies into the resource bundle).
    static func resourceURL(_ name: String, _ fileExtension: String) -> URL? {
        STResources.bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/Fonts")
    }

    /// Registers every bundled font for this process. Safe to call repeatedly and from any thread;
    /// returns whether all of them now resolve to a font.
    ///
    /// DM Serif Display isn't used by any text style (display text moved to Bodoni Moda); it stays bundled
    /// and registered for the Prologue greeting's wordmark (`greetingWordmark(_:)`).
    @discardableResult
    public static func register() -> Bool {
        _ = registration
        let names = [displayRegularName, displayItalicName, "BodoniModa-Regular", "SourceSerif4Roman-Regular"]
        return names.allSatisfy { NSFont(name: $0, size: 12) != nil }
    }

    /// Runs once per process. `CTFontManagerRegisterFontsForURLs` reports an already-registered font as a
    /// failure, which is fine here; whether the names resolve afterwards is what counts.
    private static let registration: Void = {
        let names = [
            (displayRegularName, "ttf"), (displayItalicName, "ttf"),
            ("BodoniModa[opsz,wght]", "ttf"), ("SourceSerif4[opsz,wght]", "ttf"),
        ]
        let urls = names.compactMap { resourceURL($0.0, $0.1) }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }()

    // Bodoni Moda's OpenType axis tags ('wght', 'opsz' as big-endian four-char codes).
    private static let wghtAxisTag = 0x77676874
    private static let opszAxisTag = 0x6f70737a

    /// The base (un-instantiated) Bodoni Moda `CGFont`, loaded once and reused for every size.
    private nonisolated(unsafe) static let bodoniModaBase: CGFont? = {
        guard let url = resourceURL("BodoniModa[opsz,wght]", "ttf"), let provider = CGDataProvider(url: url as CFURL) else { return nil }
        return CGFont(provider)
    }()

    /// Bodoni Moda at a held, thin weight (400 — the lightest this family ships) with the optical-size
    /// axis pushed to its display maximum (96 of 6...96). Named static instances only vary weight and
    /// default to a text optical size (11); this axis is what actually makes Bodoni tall and elegant,
    /// independent of weight. Checked legible down to the 18 pt sidebar tool names, so it is used flat
    /// at every display-mapped size rather than scaled down for small text.
    private static func bodoniModaDisplay(_ size: CGFloat) -> Font {
        guard let base = bodoniModaBase else { return .custom("BodoniModa-Regular", size: size) }
        let variation: [CFString: Any] = [kCTFontVariationAttribute: [wghtAxisTag: 400, opszAxisTag: 96]]
        let descriptor = CTFontDescriptorCreateWithAttributes(variation as CFDictionary)
        let ctFont = CTFontCreateWithGraphicsFont(base, size, nil, descriptor)
        return Font(ctFont)
    }

    private static func sourceSerifName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "SourceSerif4Roman-Bold"
        case .semibold: "SourceSerif4Roman-SemiBold"
        case .medium: "SourceSerif4Roman-Medium"
        default: "SourceSerif4Roman-Regular"
        }
    }
}
