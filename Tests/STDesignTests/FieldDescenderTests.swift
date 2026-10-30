import AppKit
import Observation
import SwiftUI
import Testing
@testable import STDesign

// A text field's AppKit view cuts its glyphs off at its bottom edge. Where the field draws its own glyphs (text too
// long for it, right-to-left text, and the number and slider value fields, which have no overlay), a view shorter than
// its line loses the descenders of g, y and p. About one launch in 10 to 40, SwiftUI sizes the view to another font's
// line (17 pt for a 14 pt field's 20 pt line). These tests make the view short the way SwiftUI does, in a window that
// is never shown, and look at the pixels below the baseline.

private final class FixedScaleWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
}

/// The editable AppKit field inside `view`.
@MainActor
private func editableField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { editableField(in: $0) }.first
}

/// Every editable AppKit field inside `view`, left to right.
@MainActor
private func editableFields(in view: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    func visit(_ view: NSView) {
        if let field = view as? NSTextField, field.isEditable { found.append(field) } else { view.subviews.forEach(visit) }
    }
    visit(view)
    return found.sorted { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX }
}

@MainActor
private func guards(in view: NSView) -> [STFieldLineGuard.GuardView] {
    var found: [STFieldLineGuard.GuardView] = []
    func visit(_ view: NSView) {
        if let guardView = view as? STFieldLineGuard.GuardView { found.append(guardView) } else { view.subviews.forEach(visit) }
    }
    visit(view)
    return found
}

/// A view hosted in an unshown window and drawn at 2x.
@MainActor
private final class Rig {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let size: CGSize

    init<V: View>(_ view: V, size: CGSize = CGSize(width: 320, height: 60)) {
        _ = NSApplication.shared
        self.size = size
        host = hostingView(AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading)))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        window = FixedScaleWindow(contentRect: host.frame)
        window.contentView = host
        spin(0.2)
    }

    isolated deinit {
        window.contentView = nil
    }

    func spin(_ seconds: TimeInterval) {
        let end = SuspendingClock.now.advanced(by: .seconds(seconds))
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        } while SuspendingClock.now < end
    }

    func capture() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    var field: NSTextField? { editableField(in: host) }

    /// The field's frame in the hosting view's coordinates, top-left origin.
    func fieldRect() -> CGRect? {
        guard let field else { return nil }
        let rect = field.convert(field.bounds, to: host)
        return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Sizes the field's AppKit view `delta` points short of its line, as SwiftUI does when it measures another font:
    /// the view SwiftUI wraps the field in is as short as the field, both keep their tops where they were, and nothing
    /// is laid out again.
    func shrinkField(by delta: CGFloat) {
        guard let field else { return }
        shrink(field, by: delta)
    }

    func shrink(_ field: NSTextField, by delta: CGFloat) {
        guard let wrapper = field.superview else { return }
        wrapper.setFrameSize(NSSize(width: wrapper.frame.width, height: wrapper.frame.height - delta))
        // The wrapper isn't flipped, so its y runs from the bottom: the field's top stays put when its y is the
        // wrapper's height less its own.
        let height = field.frame.height - delta
        field.frame = NSRect(x: field.frame.minX, y: wrapper.isFlipped ? 0 : wrapper.bounds.height - height,
                             width: field.frame.width, height: height)
        field.needsDisplay = true
        wrapper.needsDisplay = true
    }
}

/// Ink is light: the text is white-ish on the dark appearance's near-black surface.
private func isInk(_ data: UnsafeMutablePointer<UInt8>, _ offset: Int) -> Bool {
    Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2]) > 3 * 110
}

/// The pixel rows, counted from `top`, that hold ink within `rows` rows of it.
private func inkRows(_ rep: NSBitmapImageRep, from top: Int, rows: Int) -> [Int] {
    guard let data = rep.bitmapData else { return [] }
    var found: [Int] = []
    for y in top..<min(rep.pixelsHigh, top + rows) {
        for x in 0..<rep.pixelsWide where isInk(data, y * rep.bytesPerRow + x * 4) {
            found.append(y - top)
            break
        }
    }
    return found
}

/// How many ink pixels lie in rows `lower..<upper`, counted from `top`.
private func inkCount(_ rep: NSBitmapImageRep, from top: Int, rows lower: Int, to upper: Int) -> Int {
    guard let data = rep.bitmapData else { return 0 }
    var count = 0
    for y in (top + lower)..<min(rep.pixelsHigh, top + upper) {
        for x in 0..<rep.pixelsWide where isInk(data, y * rep.bytesPerRow + x * 4) { count += 1 }
    }
    return count
}

/// Text too long for a 150 pt field, with descenders all the way along.
private let longText = "Wolverine gypsy jumping quickly by pygmy lynx, my papyrus, gypsy queen"
/// Hebrew with final forms that descend, then Latin descenders. The field shows its own glyphs for right-to-left text.
private let rightToLeftText = "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E7}\u{05DA}\u{05DF}\u{05E3}\u{05E5} gypsy"

/// A field that draws its own glyphs.
private struct Scenario: CustomTestStringConvertible {
    let name: String
    /// The point size and weight the field's line height is measured at.
    let size: CGFloat
    let weight: Font.Weight
    let build: @MainActor () -> AnyView
    var testDescription: String { name }
}

@MainActor private let scenarios: [Scenario] = [
    Scenario(name: "STTextField, text too long for it", size: 14, weight: .regular) {
        AnyView(STTextField("Name", text: .constant(longText)).frame(width: 150).background(STColor.background))
    },
    Scenario(name: "STTextField, right-to-left text", size: 14, weight: .regular) {
        AnyView(STTextField("Name", text: .constant(rightToLeftText)).frame(width: 150).background(STColor.background))
    },
    Scenario(name: "a number field", size: 13, weight: .medium) {
        AnyView(TextField("Value", text: .constant("12 px gypsy"))
            .textFieldStyle(.plain)
            .font(STFont.figures(13))
            .stFieldLineHeight(13, weight: .medium)
            .foregroundStyle(STColor.ink)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .background(STColor.surface))
    },
    Scenario(name: "the slider's value field", size: 14, weight: .medium) {
        AnyView(STSlider(value: .constant(12), in: 0...100, step: 1, label: "Size", valueText: { "\(Int($0)) px" })
            .startingInEditMode()
            .frame(width: 300)
            .background(STColor.background))
    },
]

/// Moves a hosted field's width, to make SwiftUI lay it out again.
@MainActor @Observable
private final class WidthBox {
    var width: CGFloat = 150
}

@MainActor
@Suite("Text field descenders", .serialized)
struct FieldDescenderTests {
    @Test(arguments: 0..<4)
    func aFieldSizedRightIsAsTallAsItsLine(index: Int) throws {
        let scenario = scenarios[index]
        let rig = Rig(scenario.build())
        let field = try #require(rig.field, "\(scenario.name): no AppKit field")
        #expect(field.frame.height >= STFont.textLineHeight(scenario.size, weight: scenario.weight) - 0.01)
    }

    /// With the AppKit view short of its line, the glyphs below its bottom edge are still drawn: the lowest ink is as
    /// low as at full height, and the rows where the descenders go keep their ink.
    @Test(arguments: 0..<4, [2.0, 3.0, 5.0])
    func descendersAreDrawnWhateverHeightTheViewGets(index: Int, delta: CGFloat) throws {
        let scenario = scenarios[index]
        let reference = Rig(scenario.build())
        let rect = try #require(reference.fieldRect(), "\(scenario.name): no AppKit field")
        let top = Int(rect.minY * 2)
        let band = Int(rect.height * 2) + 12
        let full = reference.capture()
        let referenceBottom = try #require(inkRows(full, from: top, rows: band).last, "\(scenario.name): the field draws nothing")
        #expect(inkCount(full, from: top, rows: referenceBottom - 5, to: referenceBottom + 1) > 0)

        let rig = Rig(scenario.build())
        rig.shrinkField(by: delta)
        rig.spin(0.1)
        let short = rig.capture()
        let shortBottom = try #require(inkRows(short, from: top, rows: band).last, "\(scenario.name): the short field draws nothing")
        #expect(shortBottom >= referenceBottom - 1,
                "\(scenario.name), \(delta) pt short: the lowest ink is \(shortBottom) px down, \(referenceBottom) at full height")
        let lowest = max(0, referenceBottom - Int(delta * 2) - 1)
        let kept = inkCount(short, from: top, rows: lowest, to: referenceBottom + 1)
        let wanted = inkCount(full, from: top, rows: lowest, to: referenceBottom + 1)
        #expect(Double(kept) >= Double(wanted) * 0.9,
                "\(scenario.name), \(delta) pt short: \(kept) ink pixels where the descenders go, \(wanted) at full height")
    }

    /// Making the view tall again moves nothing: the field's top edge stays where SwiftUI put it.
    @Test(arguments: 0..<4)
    func theFieldKeepsItsTopEdge(index: Int) throws {
        let scenario = scenarios[index]
        let rig = Rig(scenario.build())
        let before = try #require(rig.fieldRect(), "\(scenario.name): no AppKit field")
        rig.shrinkField(by: 3)
        rig.spin(0.1)
        let after = try #require(rig.fieldRect())
        #expect(abs(after.minY - before.minY) < 0.01, "\(scenario.name): the top moved from \(before.minY) to \(after.minY)")
        #expect(abs(after.height - before.height) < 0.01, "\(scenario.name): \(before.height) pt tall before, \(after.height) after")
    }

    /// SwiftUI lays the field out again and sizes it short again: it ends up one line tall again, and the layout
    /// settles instead of going back and forth.
    @Test func aLayoutAfterwardsLeavesTheFieldOneLineTall() throws {
        let box = WidthBox()
        let line = STFont.textLineHeight(14)
        let rig = Rig(WidthField(box: box))
        let field = try #require(rig.field)
        rig.shrinkField(by: 4)
        rig.spin(0.1)
        #expect(field.frame.height >= line - 0.01)
        box.width = 200
        rig.spin(0.3)
        #expect(field.frame.height >= line - 0.01)
        let settled = field.frame
        rig.spin(0.3)
        #expect(field.frame == settled, "the field's frame kept changing with nothing changing")
        #expect(!rig.host.needsLayout, "the hosting view keeps asking for layout")
    }

    /// The guard is a background: a click at the field's middle reaches the field, never the guard or the view around it.
    @Test func aClickGoesThroughTheGuardToTheField() throws {
        let rig = Rig(STTextField("Name", text: .constant("gypsy")).frame(width: 150).background(STColor.background))
        let field = try #require(rig.field)
        let inHost = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: rig.host)
        let superview = try #require(rig.host.superview)
        let hit = rig.host.hitTest(rig.host.convert(inHost, to: superview))
        #expect(!(hit is STFieldLineGuard.GuardView), "the click landed on the guard")
        #expect(hit === field || hit?.isDescendant(of: field) == true, "the click landed on \(String(describing: hit))")
    }

    /// Each field has a guard of its own: shortening one leaves the other's view alone.
    @Test func eachFieldIsKeptByItsOwnGuard() throws {
        let rig = Rig(HStack(alignment: .top, spacing: 10) {
            STTextField("First", text: .constant("gypsy jqp")).frame(width: 120)
            STTextField("Second", text: .constant("gypsy jqp")).frame(width: 120)
        }.background(STColor.background))
        let fields = editableFields(in: rig.host)
        try #require(fields.count == 2)
        #expect(guards(in: rig.host).count == 2)
        let line = STFont.textLineHeight(14)
        let firstBefore = fields[0].frame
        rig.shrink(fields[1], by: 4)
        rig.spin(0.1)
        #expect(fields[1].frame.height >= line - 0.01, "the shortened field wasn't made a line tall again")
        #expect(fields[0].frame == firstBefore, "the other field's view changed")
    }

    /// A slot that holds no field has nothing to keep: the guard finds none and changes no frame.
    @Test func aSlotWithoutAFieldIsLeftAlone() throws {
        let rig = Rig(Color.red.frame(width: 50).stFieldLineHeight(14).background(STColor.background))
        rig.spin(0.2)
        let found = guards(in: rig.host)
        try #require(found.count == 1)
        #expect(found[0].watchedField == nil)
        #expect(editableFields(in: rig.host).isEmpty)
    }
}

private struct WidthField: View {
    let box: WidthBox

    var body: some View {
        STTextField("Name", text: .constant(longText))
            .frame(width: box.width)
            .background(STColor.background)
    }
}
