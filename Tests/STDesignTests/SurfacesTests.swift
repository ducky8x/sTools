import AppKit
import SwiftUI
import Testing
@testable import STDesign

// MARK: - Typing animation model

private func edit(_ old: String, _ new: String) -> TypingEdit? {
    TypingAnimationModel.diff(from: old, to: new)
}

@Suite("TypingAnimationModel")
struct TypingAnimationModelTests {
    @Test func identicalStringsHaveNoEdit() {
        #expect(edit("", "") == nil)
        #expect(edit("abc", "abc") == nil)
    }

    @Test func typingAtTheEnd() throws {
        let e = try #require(edit("ab", "abc"))
        #expect(e.removed == 2..<2)
        #expect(e.inserted == 2..<3)
        #expect(e.insertedText == "c")
        #expect(e.removedText == "")
        #expect(e.insertedUTF16 == 2..<3)
    }

    @Test func typingIntoAnEmptyField() throws {
        let e = try #require(edit("", "a"))
        #expect(e.removed == 0..<0)
        #expect(e.inserted == 0..<1)
    }

    @Test func typingInTheMiddleAndAtTheStart() throws {
        let middle = try #require(edit("acd", "abcd"))
        #expect(middle.inserted == 1..<2)
        #expect(middle.insertedText == "b")
        let start = try #require(edit("bcd", "abcd"))
        #expect(start.inserted == 0..<1)
    }

    @Test func backspaceAtTheEndAndInTheMiddle() throws {
        let end = try #require(edit("abc", "ab"))
        #expect(end.removed == 2..<3)
        #expect(end.removedText == "c")
        #expect(end.inserted == 2..<2)
        #expect(end.removalAnchorUTF16 == 2)
        let middle = try #require(edit("abcd", "abd"))
        #expect(middle.removed == 2..<3)
        #expect(middle.removedText == "c")
    }

    @Test func clearingTheField() throws {
        let e = try #require(edit("hello", ""))
        #expect(e.removed == 0..<5)
        #expect(e.removedText == "hello")
        #expect(e.inserted == 0..<0)
    }

    @Test func multiCharacterPaste() throws {
        let e = try #require(edit("ad", "abcd"))
        #expect(e.inserted == 1..<3)
        #expect(e.insertedText == "bc")
        #expect(e.insertedUTF16 == 1..<3)
        #expect(e.removed == 1..<1)
    }

    @Test func pasteReplacingASelection() throws {
        let e = try #require(edit("hello world", "heXrld"))
        #expect(e.removed == 2..<8)
        #expect(e.removedText == "llo wo")
        #expect(e.inserted == 2..<3)
        #expect(e.insertedText == "X")
    }

    @Test func selectionReplacedByLongerText() throws {
        let e = try #require(edit("one two three", "one 2 three"))
        #expect(e.removedText == "two")
        #expect(e.insertedText == "2")
        #expect(e.inserted == 4..<5)
    }

    @Test func repeatedCharactersReportTheEndOfTheRun() throws {
        let typed = try #require(edit("aa", "aaa"))
        #expect(typed.inserted == 2..<3)
        let deleted = try #require(edit("aaa", "aa"))
        #expect(deleted.removed == 2..<3)
    }

    @Test func koreanCompositionReplacesTheLastSyllable() throws {
        let first = try #require(edit("", "ㅎ"))
        #expect(first.inserted == 0..<1)
        let second = try #require(edit("ㅎ", "하"))
        #expect(second.removed == 0..<1)
        #expect(second.inserted == 0..<1)
        let third = try #require(edit("하", "한"))
        #expect(third.removedText == "하")
        #expect(third.insertedText == "한")
        let next = try #require(edit("한", "한ㄱ"))
        #expect(next.inserted == 1..<2)
        let composed = try #require(edit("한ㄱ", "한그"))
        #expect(composed.removed == 1..<2)
        #expect(composed.inserted == 1..<2)
        #expect(composed.insertedText == "그")
    }

    @Test func conjoiningJamoFormOneCluster() throws {
        let lead = "\u{1112}"
        let syllable = "\u{1112}\u{1161}"
        let e = try #require(edit("a" + lead, "a" + syllable))
        #expect(e.removed == 1..<2)
        #expect(e.inserted == 1..<2)
        #expect(e.insertedUTF16 == 1..<3)
    }

    @Test func combiningAccentReplacesTheBaseLetter() throws {
        let e = try #require(edit("ae", "ae\u{301}"))
        #expect(e.removed == 1..<2)
        #expect(e.inserted == 1..<2)
        #expect(e.insertedUTF16 == 1..<3)
    }

    @Test func emojiSequencesAreSingleUnits() throws {
        let family = "👨‍👩‍👧"
        #expect(family.count == 1)
        let typed = try #require(edit("a", "a" + family))
        #expect(typed.inserted == 1..<2)
        #expect(typed.insertedUTF16 == 1..<(1 + family.utf16.count))
        let followed = try #require(edit("a" + family, "a" + family + "b"))
        #expect(followed.inserted == 2..<3)
        #expect(followed.insertedUTF16 == (1 + family.utf16.count)..<(2 + family.utf16.count))
        let deleted = try #require(edit("a" + family + "b", "ab"))
        #expect(deleted.removed == 1..<2)
        #expect(deleted.removedText == family)
        #expect(deleted.removalAnchorUTF16 == 1)
    }

    @Test func skinToneAndFlagFormationReplaceTheCluster() throws {
        let tone = try #require(edit("👍", "👍🏽"))
        #expect(tone.removed == 0..<1)
        #expect(tone.inserted == 0..<1)
        #expect(tone.insertedUTF16 == 0..<4)
        let flag = try #require(edit("🇰", "🇰🇷"))
        #expect(flag.removed == 0..<1)
        #expect(flag.inserted == 0..<1)
        #expect(flag.insertedUTF16 == 0..<4)
    }

    @Test func editsAlwaysReassembleTheNewString() {
        let alphabet: [String] = ["a", "b", "c", " ", "é", "e\u{301}", "👍", "👍🏽", "👨‍👩‍👧", "🇰🇷", "ㅎ", "한", "\u{1112}\u{1161}"]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        func randomString() -> String { (0..<next(8)).map { _ in alphabet[next(alphabet.count)] }.joined() }

        for _ in 0..<2000 {
            let old = randomString()
            let new = randomString()
            let oldChars = Array(old), newChars = Array(new)
            guard let e = edit(old, new) else {
                #expect(old == new)
                continue
            }
            let rebuilt = String(oldChars[..<e.removed.lowerBound]) + String(newChars[e.inserted]) + String(oldChars[e.removed.upperBound...])
            #expect(rebuilt == new, "\(old) -> \(new)")
            #expect(e.removedText == String(oldChars[e.removed]))
            #expect(e.insertedText == String(newChars[e.inserted]))
            #expect(e.removed.lowerBound == e.inserted.lowerBound)
            let utf16 = Array(new.utf16)
            let slice = String(decoding: utf16[e.insertedUTF16], as: UTF16.self)
            #expect(slice == e.insertedText, "\(old) -> \(new)")
        }
    }

    @Test func rightToLeftTextIsDetected() {
        #expect(TypingAnimationModel.containsRightToLeft("שלום"))
        #expect(TypingAnimationModel.containsRightToLeft("abc مرحبا"))
        #expect(!TypingAnimationModel.containsRightToLeft("Hello 한글 👍"))
    }

    @Test func shakeStartsAndEndsAtRest() {
        #expect(STShakeEffect.offset(at: 0) == 0)
        #expect(abs(STShakeEffect.offset(at: 1)) < 1e-9)
        #expect(abs(STShakeEffect.offset(at: 7)) < 1e-9)
        #expect(abs(STShakeEffect.offset(at: 0.25 / 3)) > 2)
        #expect(abs(STShakeEffect.offset(at: 0.25 / 3)) <= STShakeEffect.amplitude)
    }
}

// MARK: - Offscreen rendering helpers

/// A borderless window with a fixed backing scale. A plain window takes the scale of the display it's on,
/// and SwiftUI lays text out and rasterizes it at that scale, so a render would change with the main display.
private final class FixedScaleWindow: NSWindow {
    private let scale: CGFloat

    init(contentRect: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
    }

    override var backingScaleFactor: CGFloat { scale }
}

/// A view hosted in an unshown window, drawn to bitmaps at `scale` pixels per point (2x by default, as a
/// Retina display would). The window reports the same scale, so text is rasterized at the scale it's captured
/// at whichever display is main; otherwise a 1x main display blurs plain `Text` in a 2x capture.
@MainActor
private final class Hosted {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    private let size: CGSize
    private let scale: Int

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, scale: Int = 2) {
        _ = NSApplication.shared
        host = hostingView(AnyView(view.frame(width: width)))
        self.scale = scale
        size = CGSize(width: width, height: height ?? ceil(host.fittingSize.height))
        host.frame = CGRect(origin: .zero, size: size)
        window = FixedScaleWindow(contentRect: host.frame, scale: CGFloat(scale))
        window.contentView = host
        spin(0.12)
    }

    func spin(_ seconds: TimeInterval) {
        let end = SuspendingClock.now.advanced(by: .seconds(seconds))
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        } while SuspendingClock.now < end
    }

    func capture() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    deinit {
        MainActor.assumeIsolated { window.contentView = nil }
    }
}

@MainActor
private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, scale: Int = 2) -> NSBitmapImageRep {
    Hosted(view, width: width, height: height, scale: scale).capture()
}

/// The text rendering tests run at both: a standard display and a Retina one.
private let renderScales = [1, 2]

// Bars on pixel sums are set for a 2x render. Ink covers an area, so its bar shrinks with the pixel count (a
// quarter at 1x); two renders of the same glyphs differ along the glyph edges, so that bar shrinks with the
// edges' length (half at 1x).
private func inkBar(_ at2x: Double, scale: Int) -> Double { at2x * Double(scale * scale) / 4 }
private func edgeBar(_ at2x: Double, scale: Int) -> Double { at2x * Double(scale) / 2 }

private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    guard let data = rep.bitmapData else { return (0, 0, 0) }
    let p = data + y * rep.bytesPerRow + x * 4
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

private func luminance(_ rep: NSBitmapImageRep) -> [[Double]] {
    guard let data = rep.bitmapData else { return [] }
    return (0..<rep.pixelsHigh).map { y in
        (0..<rep.pixelsWide).map { x in
            let p = data + y * rep.bytesPerRow + x * 4
            return (Double(p[0]) + Double(p[1]) + Double(p[2])) / (3 * 255)
        }
    }
}

private func inkMass(_ rep: NSBitmapImageRep) -> Double {
    luminance(rep).flatMap { $0 }.filter { $0 > 0.15 }.reduce(0, +)
}

/// The pixel shift (within 3 px) that best lays `b` over `a`, and how well it fits, over `a`'s top `rows` pixel rows (all
/// of them by default). Renders of different sizes record an issue and fit nowhere, instead of reading past the smaller
/// one and crashing the test run.
private func bestShift(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                       rows: Int = .max) -> (dx: Int, dy: Int, error: Double, errorUnshifted: Double) {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
        Issue.record("Renders differ in size: \(a.pixelsWide)×\(a.pixelsHigh) and \(b.pixelsWide)×\(b.pixelsHigh) px")
        return (0, 0, .infinity, .infinity)
    }
    let la = luminance(a), lb = luminance(b)
    let margin = 4
    var best = (dx: 0, dy: 0, error: Double.infinity)
    var unshifted = 0.0
    for dy in -3...3 {
        for dx in -3...3 {
            var error = 0.0
            for y in margin..<min(a.pixelsHigh - margin, rows) {
                for x in margin..<(a.pixelsWide - margin) {
                    let d = la[y][x] - lb[y + dy][x + dx]
                    error += d * d
                }
            }
            if dx == 0 && dy == 0 { unshifted = error }
            if error < best.error { best = (dx, dy, error) }
        }
    }
    return (best.dx, best.dy, best.error, unshifted)
}

@MainActor private func theme(scale: Double) -> STTheme { STTheme(textScale: scale) }

// MARK: - Text field alignment

@MainActor
@Suite("STTextField rendering")
struct STTextFieldRenderingTests {
    private let sample = "Wolverine gypsy 01"

    private func field(points: Double, revealed: Bool, text: String? = nil) -> some View {
        STTextField("Name", text: .constant(text ?? sample))
            .environment(\.stTheme, theme(scale: points / 14))
            .environment(\.stRevealsNativeText, revealed)
            .background(STColor.background)
    }

    private func fieldRep(points: Double, revealed: Bool, text: String? = nil, scale: Int) -> NSBitmapImageRep {
        render(field(points: points, revealed: revealed, text: text), width: 260, scale: scale)
    }

    /// The field showing its own glyphs, and how many pixel rows from the top of the render it can draw them in: down
    /// to its AppKit view's bottom edge, the bottom of its line. Now and then a process has SwiftUI size that view to
    /// another font's line (see `stFieldLineHeight`); a shorter view still sits where the field belongs, but AppKit
    /// cuts its glyphs off at that edge, so there's nothing below it to compare the overlay with.
    private func nativeFieldRep(points: Double, scale: Int) -> (rep: NSBitmapImageRep, drawableRows: Int) {
        let hosted = Hosted(field(points: points, revealed: true), width: 260, scale: scale)
        let rep = hosted.capture()
        guard let appKit = appKitField(in: hosted.host) else {
            Issue.record("The field has no AppKit text field")
            return (rep, rep.pixelsHigh)
        }
        let frame = appKit.convert(appKit.bounds, to: hosted.host)
        let bottom = hosted.host.isFlipped ? frame.maxY : hosted.host.bounds.height - frame.minY
        return (rep, Int((bottom * CGFloat(scale)).rounded()))
    }

    @Test(arguments: [12.0, 12.6, 13.0, 14.0, 15.0, 16.0, 17.0, 18.2], renderScales)
    func overlayTextLandsOnTheRealFieldsGlyphs(points: Double, scale: Int) {
        let (native, drawableRows) = nativeFieldRep(points: points, scale: scale)
        let overlay = fieldRep(points: points, revealed: false, scale: scale)
        #expect(native.pixelsWide == overlay.pixelsWide && native.pixelsHigh == overlay.pixelsHigh)
        #expect(inkMass(native) > inkBar(100, scale: scale))
        let shift = bestShift(native, overlay, rows: drawableRows)
        // Not one pixel off: at 2x that's half a point, at 1x (where layout snaps to whole points) a point.
        #expect(shift.dx == 0 && shift.dy == 0, "size \(points) at \(scale)x: best shift \(shift.dx),\(shift.dy) px")
        #expect(shift.errorUnshifted < edgeBar(60, scale: scale), "size \(points) at \(scale)x: residual \(shift.errorUnshifted)")
    }

    @Test(arguments: renderScales)
    func overlayHidesTheFieldsOwnGlyphs(scale: Int) {
        let overlay = fieldRep(points: 14, revealed: false, scale: scale)
        let empty = fieldRep(points: 14, revealed: false, text: "", scale: scale)
        #expect(inkMass(overlay) > inkMass(empty) + inkBar(100, scale: scale))
    }

    @Test(arguments: renderScales)
    func placeholderShowsWhenEmpty(scale: Int) {
        let empty = fieldRep(points: 14, revealed: false, text: "", scale: scale)
        let baselineOnly = render(
            Color.clear.frame(height: 1).background(STColor.surface).background(STColor.background), width: 260, height: 1, scale: scale)
        #expect(inkMass(empty) > inkMass(baselineOnly) + inkBar(20, scale: scale))
    }
}

// MARK: - Field line height

/// The editable AppKit field inside `view`.
@MainActor
private func appKitField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { appKitField(in: $0) }.first
}

@MainActor
@Suite("Field line height")
struct FieldLineHeightTests {
    /// `stFieldLineHeight` holds a field to `STFont.textLineHeight`, so that has to be the height the real field's line
    /// takes: for both field sizes (14 pt text, 13 pt figures) at every Text Size, in both weights the fields use. The
    /// half points pin down which way the field rounds its font's size.
    @Test(arguments: [Font.Weight.regular, .medium])
    func isTheHeightOfTheRealFieldsLine(weight: Font.Weight) throws {
        let textSizes = [13.0, 14.0].flatMap { base in stride(from: 0.9, through: 1.3001, by: 0.025).map { base * $0 } }
        for size in textSizes + [12.5, 13.5, 14.5, 15.5, 16.5, 17.5] {
            let host = hostingView(TextField("Name", text: .constant("Wolverine gypsy 01"))
                .textFieldStyle(.plain)
                .font(weight == .medium ? STFont.figures(size) : STFont.text(size))
                .frame(width: 200))
            host.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
            host.layoutSubtreeIfNeeded()
            let field = try #require(appKitField(in: host))
            let cell = try #require(field.cell)
            #expect(cell.cellSize.height == STFont.textLineHeight(size, weight: weight), "\(size) pt \(weight)")
        }
    }
}

// MARK: - Typing renderer

@MainActor
@Suite("STTypingRenderer")
struct STTypingRendererTests {
    private let font = STFont.text(14)

    private func rendered(_ text: String, progress: Double, inserted: Range<Int>? = nil, removed: String = "", anchor: Int = 0,
                          rise: CGFloat = 2, shrinks: Bool = true, scale: Int) -> NSBitmapImageRep {
        render(
            Text(text).font(font).foregroundStyle(STColor.ink).fixedSize()
                .textRenderer(STTypingRenderer(progress: progress, inserted: inserted, removedText: removed, removalAnchor: anchor,
                                               rise: rise, shrinks: shrinks, font: font, color: STColor.ink))
                .padding(12)
                .frame(width: 160, alignment: .leading)
                .background(STColor.background),
            width: 160, scale: scale)
    }

    private func plain(_ text: String, scale: Int) -> NSBitmapImageRep {
        render(Text(text).font(font).foregroundStyle(STColor.ink).fixedSize().padding(12)
                .frame(width: 160, alignment: .leading).background(STColor.background), width: 160, scale: scale)
    }

    @Test(arguments: renderScales)
    func finishedAnimationLooksLikePlainText(scale: Int) {
        let done = rendered("Steve", progress: 1, inserted: 4..<5, scale: scale)
        let reference = plain("Steve", scale: scale)
        let shift = bestShift(reference, done)
        #expect(shift.errorUnshifted < edgeBar(1, scale: scale))
    }

    @Test(arguments: renderScales)
    func newestGlyphIsInvisibleAtTheStart(scale: Int) {
        let start = rendered("Steve", progress: 0, inserted: 4..<5, scale: scale)
        let without = plain("Stev", scale: scale)
        let full = plain("Steve", scale: scale)
        #expect(inkMass(start) < inkMass(full) - inkBar(3, scale: scale))
        #expect(abs(inkMass(start) - inkMass(without)) < edgeBar(2, scale: scale))
    }

    @Test(arguments: renderScales)
    func newestGlyphIsPartlyThereHalfway(scale: Int) {
        let start = inkMass(rendered("Steve", progress: 0, inserted: 4..<5, scale: scale))
        let half = inkMass(rendered("Steve", progress: 0.5, inserted: 4..<5, scale: scale))
        let end = inkMass(rendered("Steve", progress: 1, inserted: 4..<5, scale: scale))
        #expect(start < half && half < end)
    }

    @Test(arguments: renderScales)
    func glyphsRiseFromBelow(scale: Int) {
        let reference = plain("Steve", scale: scale)
        let early = rendered("Steve", progress: 0.01, inserted: 0..<5, rise: 8, scale: scale)
        let late = rendered("Steve", progress: 0.99, inserted: 0..<5, rise: 8, scale: scale)
        // Nearly opaque and almost in place at the end; clearly offset at the start.
        #expect(bestShift(reference, late).errorUnshifted < bestShift(reference, early).errorUnshifted)
    }

    @Test(arguments: renderScales)
    func untouchedGlyphsStayPut(scale: Int) {
        let start = rendered("Steve", progress: 0, inserted: 4..<5, scale: scale)
        let without = plain("Stev", scale: scale)
        #expect(bestShift(without, start).errorUnshifted < edgeBar(1, scale: scale))
    }

    @Test(arguments: renderScales)
    func reducedMotionFadesWithoutMoving(scale: Int) {
        let faded = rendered("Steve", progress: 0.5, inserted: 4..<5, rise: 0, shrinks: false, scale: scale)
        let slid = rendered("Steve", progress: 0.5, inserted: 4..<5, rise: 8, scale: scale)
        let reference = plain("Steve", scale: scale)
        #expect(inkMass(faded) < inkMass(reference))
        #expect(bestShift(reference, faded).dy == 0)
        #expect(bestShift(reference, slid).errorUnshifted > bestShift(reference, faded).errorUnshifted)
    }

    @Test(arguments: renderScales)
    func deletedGlyphShrinksOutAtTheEndOfTheText(scale: Int) {
        let remaining = plain("Stev", scale: scale)
        let leaving = rendered("Stev", progress: 0.2, removed: "e", anchor: 4, scale: scale)
        let gone = rendered("Stev", progress: 1, removed: "e", anchor: 4, scale: scale)
        #expect(inkMass(leaving) > inkMass(remaining) + inkBar(2, scale: scale))
        #expect(bestShift(remaining, gone).errorUnshifted < edgeBar(1, scale: scale))
    }

    @Test(arguments: renderScales)
    func deletedGlyphInTheMiddleAppearsAtItsAnchor(scale: Int) {
        let remaining = plain("Stve", scale: scale)
        let leaving = rendered("Stve", progress: 0.2, removed: "e", anchor: 2, scale: scale)
        #expect(inkMass(leaving) > inkMass(remaining) + inkBar(2, scale: scale))
    }

    @Test(arguments: renderScales)
    func emojiGlyphsAnimateAsOne(scale: Int) {
        let family = "👨‍👩‍👧"
        let text = "a" + family
        let start = rendered(text, progress: 0, inserted: 1..<(1 + family.utf16.count), scale: scale)
        let onlyA = plain("a", scale: scale)
        #expect(inkMass(start) < inkMass(onlyA) + edgeBar(2, scale: scale))
    }
}

// MARK: - Text field behavior

@MainActor
@Observable
private final class TextBox {
    var text: String
    init(_ text: String) { self.text = text }
}

private struct BoundField: View {
    let box: TextBox
    var isInvalid = false
    var body: some View {
        STTextField("Name", text: Binding(get: { box.text }, set: { box.text = $0 }), isInvalid: isInvalid)
            .background(STColor.background)
    }
}

@MainActor
@Suite("STTextField behavior")
struct STTextFieldBehaviorTests {
    @Test func typedTextSettlesIntoTheFinalLook() {
        let box = TextBox("Stev")
        let hosted = Hosted(BoundField(box: box), width: 200)
        box.text = "Steve"
        hosted.spin(0.5)
        let typed = hosted.capture()
        let reference = render(BoundField(box: TextBox("Steve")), width: 200)
        #expect(bestShift(reference, typed).errorUnshifted < 2)
    }

    @Test func deletedTextLeavesNoGhostBehind() {
        let box = TextBox("Steve")
        let hosted = Hosted(BoundField(box: box), width: 200)
        box.text = "Stev"
        hosted.spin(0.5)
        let deleted = hosted.capture()
        let reference = render(BoundField(box: TextBox("Stev")), width: 200)
        #expect(bestShift(reference, deleted).errorUnshifted < 2)
    }

    @Test func pastedTextSettlesToo() {
        let box = TextBox("")
        let hosted = Hosted(BoundField(box: box), width: 200)
        box.text = "Wolverine gypsy"
        hosted.spin(0.5)
        let pasted = hosted.capture()
        let reference = render(BoundField(box: TextBox("Wolverine gypsy")), width: 200)
        #expect(bestShift(reference, pasted).errorUnshifted < 2)
    }

    @Test func textTooLongForTheFieldShowsTheFieldsOwnGlyphs() {
        let long = String(repeating: "Wolverine ", count: 8)
        let shown = render(BoundField(box: TextBox(long)), width: 200)
        #expect(inkMass(shown) > 200)
    }

    @Test func invalidFieldTintsItsBaselineDanger() {
        let valid = render(BoundField(box: TextBox("")), width: 200)
        let invalid = render(BoundField(box: TextBox(""), isInvalid: true), width: 200)
        let y = valid.pixelsHigh - 1
        let validPixel = pixel(valid, x: 100, y: y)
        let invalidPixel = pixel(invalid, x: 100, y: y)
        #expect(invalidPixel.r > invalidPixel.b + 40)
        #expect(invalidPixel.r > validPixel.r + 40)
    }

    @Test func baselineIsTheStrokeColorWhenNotFocused() {
        let field = render(BoundField(box: TextBox("")), width: 200)
        let p = pixel(field, x: 100, y: field.pixelsHigh - 1)
        let stroke = (r: 0x6E, g: 0x65, b: 0x5B)
        #expect(abs(p.r - stroke.r) < 6 && abs(p.g - stroke.g) < 6 && abs(p.b - stroke.b) < 6)
    }

    @Test func fieldHasSurfaceFill() {
        let field = render(STTextField("Name", text: .constant("")), width: 200)
        let p = pixel(field, x: 190, y: 4)
        #expect(abs(p.r - 0x15) < 4 && abs(p.g - 0x12) < 4 && abs(p.b - 0x0F) < 4)
    }
}

// MARK: - Layout surfaces

private func isClose(_ p: (r: Int, g: Int, b: Int), hex: String, tolerance: Int = 6) -> Bool {
    let v = Int(hex.dropFirst(), radix: 16) ?? 0
    return abs(p.r - ((v >> 16) & 0xFF)) <= tolerance && abs(p.g - ((v >> 8) & 0xFF)) <= tolerance && abs(p.b - (v & 0xFF)) <= tolerance
}

@MainActor
@Suite("Surfaces rendering")
struct SurfacesRenderingTests {
    @Test func plateHasSurfaceFillRoundedCornersAndAHairline() {
        let rep = render(
            STPlate { Color.clear.frame(width: 120, height: 80) }.padding(10).background(STColor.background),
            width: 140)
        #expect(rep.pixelsWide == 280 && rep.pixelsHigh == 200)
        #expect(isClose(pixel(rep, x: 140, y: 100), hex: STPalette.surface))
        #expect(isClose(pixel(rep, x: 20, y: 20), hex: STPalette.background))
        #expect(isClose(pixel(rep, x: 20, y: 100), hex: STPalette.rule, tolerance: 14))
    }

    @Test func requirementStripShowsMarkMessageAndAction() {
        let error = render(STRequirementStrip(kind: .error, message: "Ninjabrain Bot is not running.", actionTitle: "Open", action: {})
            .background(STColor.background), width: 420)
        let warning = render(STRequirementStrip(kind: .warning, message: "Ninjabrain Bot is not running.", actionTitle: "Open", action: {})
            .background(STColor.background), width: 420)
        #expect(error.pixelsWide == 840)
        #expect(error.pixelsHigh >= 56 && error.pixelsHigh <= 100)
        #expect(inkMass(error) > 100)
        // The leading mark is red-ish for an error and gold for a warning.
        func markTint(_ rep: NSBitmapImageRep) -> Int {
            var best = 0
            for y in 0..<rep.pixelsHigh { for x in 20..<60 {
                let p = pixel(rep, x: x, y: y)
                best = max(best, p.r - p.b)
            } }
            return best
        }
        #expect(markTint(error) > 60)
        #expect(markTint(warning) > markTint(error))
    }

    @Test func requirementStripWithoutActionStillRenders() {
        let rep = render(STRequirementStrip(kind: .warning, message: "Grant Screen Recording access."), width: 420)
        #expect(inkMass(rep) > 50)
    }

    @Test func sealIsVisibleWhenStampedAndInvisibleButSizedWhenNot() {
        let stamped = render(STSeal(isStamped: true).padding(8).background(STColor.background), width: 60)
        let blank = render(STSeal(isStamped: false).padding(8).background(STColor.background), width: 60)
        #expect(stamped.pixelsWide == blank.pixelsWide && stamped.pixelsHigh == blank.pixelsHigh)
        #expect(stamped.pixelsHigh == 2 * 38)
        let center = pixel(stamped, x: stamped.pixelsWide / 2, y: stamped.pixelsHigh / 2 + 10)
        #expect(center.r > 180 && center.g > 130 && center.b < 120)
        #expect(inkMass(blank) < 1)
    }

    @Test func sealFlipsToStampedWithoutChangingSize() {
        struct Wrapper: View {
            @State var stamped = false
            let onAppear: @MainActor (@escaping @MainActor () -> Void) -> Void
            var body: some View {
                STSeal(isStamped: stamped).padding(8).background(STColor.background)
                    .onAppear { onAppear { stamped = true } }
            }
        }
        var flip: (@MainActor () -> Void)?
        let hosted = Hosted(Wrapper(onAppear: { flip = $0 }), width: 60)
        #expect(inkMass(hosted.capture()) < 1)
        flip?()
        hosted.spin(0.6)
        #expect(inkMass(hosted.capture()) > 50)
    }

    @Test func settingsRowDrawsARuleOnlyWhenAsked() {
        func row(_ rule: Bool) -> NSBitmapImageRep {
            render(STSettingsRow("Color", showsRule: rule) { Text("white").foregroundStyle(STColor.ink) }
                .background(STColor.background), width: 300)
        }
        let withRule = row(true), without = row(false)
        #expect(withRule.pixelsHigh == without.pixelsHigh)
        let y = withRule.pixelsHigh - 1
        #expect(isClose(pixel(withRule, x: 150, y: y), hex: STPalette.rule, tolerance: 14))
        #expect(isClose(pixel(without, x: 150, y: y), hex: STPalette.background))
        #expect(inkMass(withRule) > 30)
    }

    @Test func settingsRowPutsTheLabelLeftAndTheControlRight() {
        let rep = render(STSettingsRow("Color") { Text("white").foregroundStyle(STColor.ink) }.background(STColor.background), width: 300)
        func inkColumns(_ range: Range<Int>) -> Int {
            var count = 0
            for x in range { for y in 0..<(rep.pixelsHigh - 4) where pixel(rep, x: x, y: y).r > 80 { count += 1 } }
            return count
        }
        #expect(inkColumns(0..<150) > 20)
        #expect(inkColumns(150..<400) < 10)
        #expect(inkColumns(400..<600) > 20)
    }

    @Test func giltRuleIsAnAccentLineThatIsInstantWhenNotAnimating() {
        let rep = render(STGiltRule(animatesIn: false).background(STColor.background), width: 200)
        #expect(rep.pixelsHigh == 2)
        #expect(isClose(pixel(rep, x: 2, y: 0), hex: STPalette.gold))
        #expect(isClose(pixel(rep, x: 398, y: 1), hex: STPalette.gold))
    }

    @Test func giltRuleIsInstantUnderReduceMotion() {
        let theme = STTheme(motionMode: .reduced)
        let rep = render(STGiltRule().environment(\.stTheme, theme).background(STColor.background), width: 200)
        #expect(isClose(pixel(rep, x: 398, y: 0), hex: STPalette.gold))
    }

    @Test func giltRuleDrawsInFromTheLeft() {
        let hosted = Hosted(STGiltRule().background(STColor.background), width: 200)
        hosted.spin(1.0)
        let rep = hosted.capture()
        #expect(isClose(pixel(rep, x: 2, y: 0), hex: STPalette.gold))
        #expect(isClose(pixel(rep, x: 398, y: 0), hex: STPalette.gold))
    }

    @Test func pageHeaderStacksTitleRuleAndTagline() {
        let rep = render(
            STPageHeader(title: "Crosshair", tagline: "The exact center, drawn your way.") {
                Circle().fill(STColor.goldStroke).frame(width: 20, height: 20)
            }.background(STColor.background),
            width: 520)
        #expect(rep.pixelsWide == 1040)
        #expect(rep.pixelsHigh > 2 * 60)
        #expect(inkMass(rep) > 400)
        // The trailing view is at the right edge.
        let trailing = pixel(rep, x: 1040 - 22, y: 44)
        #expect(trailing.r > 150 && trailing.b < 100)
        // A one point gold line sits between the title and the tagline.
        var goldRows: [Int] = []
        for y in 0..<rep.pixelsHigh where isClose(pixel(rep, x: 200, y: y), hex: STPalette.gold, tolerance: 8) { goldRows.append(y) }
        #expect(!goldRows.isEmpty)
        #expect(goldRows.allSatisfy { $0 > 60 })
    }

    @Test func advancedDisclosureGrowsWhenExpanded() {
        func height(expanded: Bool) -> Int {
            render(STAdvancedDisclosure(isExpanded: .constant(expanded)) {
                Text("Offset").foregroundStyle(STColor.ink).frame(height: 40)
            }.background(STColor.background), width: 260).pixelsHigh
        }
        let collapsed = height(expanded: false)
        let expanded = height(expanded: true)
        #expect(collapsed < 2 * 30)
        #expect(expanded >= collapsed + 2 * 40)
    }

    @Test func advancedDisclosureShowsItsLabel() {
        let rep = render(STAdvancedDisclosure(isExpanded: .constant(false)) { EmptyView() }.background(STColor.background), width: 260)
        #expect(inkMass(rep) > 20)
    }

    @Test func advancedDisclosureToggles() {
        struct Wrapper: View {
            @State var open = false
            let capture: @MainActor (Binding<Bool>) -> Void
            var body: some View {
                STAdvancedDisclosure(isExpanded: $open) { Color.clear.frame(height: 40) }
                    .background(STColor.background)
                    .onAppear { capture($open) }
            }
        }
        var binding: Binding<Bool>?
        let hosted = Hosted(Wrapper(capture: { binding = $0 }), width: 260)
        let before = hosted.capture().pixelsHigh
        binding?.wrappedValue = true
        hosted.spin(0.8)
        #expect(hosted.capture().pixelsHigh == before)
        #expect(binding?.wrappedValue == true)
    }
}

// MARK: - Focus and input methods (real field editor)

/// A borderless window that can take focus, parked far off screen so tests never flash anything.
private final class FocusableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class FocusedField {
    let box: TextBox
    let host: NSHostingView<AnyView>
    let window: FocusableWindow
    let editor: NSTextView
    static let none = NSRange(location: NSNotFound, length: 0)

    init?(text: String = "", width: CGFloat = 200) {
        _ = NSApplication.shared
        box = TextBox(text)
        host = hostingView(AnyView(BoundField(box: box).frame(width: width)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: ceil(host.fittingSize.height))
        window = FocusableWindow(contentRect: CGRect(x: -8000, y: -8000, width: host.frame.width, height: host.frame.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        FocusedField.spin(host)
        guard let field = FocusedField.findField(host) else { return nil }
        window.makeFirstResponder(field)
        FocusedField.spin(host, 0.7)
        guard let editor = window.fieldEditor(false, for: field) as? NSTextView, window.firstResponder === editor else { return nil }
        self.editor = editor
    }

    deinit {
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    static func spin(_ host: NSView, _ seconds: TimeInterval = 0.25) {
        let end = SuspendingClock.now.advanced(by: .seconds(seconds))
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        } while SuspendingClock.now < end
    }

    static func findField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for sub in view.subviews { if let field = findField(sub) { return field } }
        return nil
    }

    func spin() { Self.spin(host) }

    func capture() -> NSBitmapImageRep {
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

/// Focus tests need a window that macOS lets become the key window. While another app is in front (for example
/// when someone is using the Mac during a test run) that is impossible, so these tests skip instead of failing.
@MainActor
private func focusedFieldOrSkip(text: String = "") throws -> FocusedField {
    guard let field = FocusedField(text: text), field.window.isKeyWindow else {
        try Test.cancel("A window can't take keyboard focus right now (another app is in front).")
    }
    return field
}

@MainActor
@Suite("STTextField input", .serialized)
struct STTextFieldInputTests {
    @Test func focusDrawsTheAccentUnderline() throws {
        let unfocused = render(BoundField(box: TextBox("")), width: 200)
        let focused = try focusedFieldOrSkip()
        var rep = focused.capture()
        let y = rep.pixelsHigh - 1
        // The underline grows with an animation; on a busy machine it can take longer than one spin to finish.
        let deadline = SuspendingClock.now.advanced(by: .seconds(3))
        while SuspendingClock.now < deadline,
              !(isClose(pixel(rep, x: 20, y: y), hex: STPalette.gold, tolerance: 12)
                && isClose(pixel(rep, x: rep.pixelsWide - 20, y: y), hex: STPalette.gold, tolerance: 12)) {
            focused.spin()
            rep = focused.capture()
        }
        // `render` draws at 2x while the focused window takes its display's scale, so each is read at its own bottom row.
        #expect(isClose(pixel(unfocused, x: 20, y: unfocused.pixelsHigh - 1), hex: STPalette.stroke))
        #expect(isClose(pixel(rep, x: 20, y: y), hex: STPalette.gold, tolerance: 12))
        #expect(isClose(pixel(rep, x: rep.pixelsWide - 20, y: y), hex: STPalette.gold, tolerance: 12))
    }

    @Test func caretUsesTheAccentNotTheTransparentTextColor() throws {
        let focused = try focusedFieldOrSkip(text: "abc")
        let caret = focused.editor.insertionPointColor.usingColorSpace(.sRGB)
        #expect(caret != nil)
        #expect((caret?.alphaComponent ?? 0) > 0.9)
        #expect((caret?.redComponent ?? 0) > 0.7 && (caret?.blueComponent ?? 1) < 0.5)
    }

    @Test func typingThroughTheFieldEditorUpdatesTheBinding() throws {
        let focused = try focusedFieldOrSkip()
        focused.editor.insertText("Hi", replacementRange: FocusedField.none)
        focused.spin()
        #expect(focused.box.text == "Hi")
        #expect(inkMass(focused.capture()) > 100)
    }

    @Test func inputMethodCompositionStaysVisibleAndCommitsThroughTheBinding() throws {
        let focused = try focusedFieldOrSkip()
        let empty = inkMass(focused.capture())
        focused.editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: FocusedField.none)
        focused.spin()
        #expect(focused.editor.hasMarkedText())
        #expect(focused.box.text == "")
        #expect(inkMass(focused.capture()) > empty + 20, "composing text is drawn by the field itself")
        focused.editor.insertText("한", replacementRange: FocusedField.none)
        focused.spin()
        #expect(focused.box.text == "한")
        #expect(!focused.editor.hasMarkedText())
    }

    @Test func selectionAndPasteGoThroughTheRealField() throws {
        let focused = try focusedFieldOrSkip(text: "hello world")
        focused.editor.setSelectedRange(NSRange(location: 2, length: 6))
        focused.editor.insertText("X", replacementRange: FocusedField.none)
        focused.spin()
        #expect(focused.box.text == "heXrld")
    }
}

@MainActor
@Suite("STTextField layout")
struct STTextFieldLayoutTests {
    @Test func idealWidthDoesNotGrowWithTheText() {
        _ = NSApplication.shared
        let short = hostingView(STTextField("Name", text: .constant("ab")))
        let long = hostingView(STTextField("Name", text: .constant(String(repeating: "Wolverine ", count: 30))))
        #expect(long.fittingSize.width == short.fittingSize.width)
    }

    @Test func heightCoversTheLineAndTheBaseline() {
        _ = NSApplication.shared
        let host = hostingView(STTextField("Name", text: .constant("ab")))
        #expect(host.fittingSize.height >= 24 && host.fittingSize.height <= 40)
    }
}
