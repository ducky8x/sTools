import AppKit
import SwiftUI
import Testing
@testable import STDesign

// A page title stays on one line and shrinks only as far as its room needs, never below 0.7 of its size. Where even that
// is too wide it wraps between words. At the window's 680 pt minimum the page column is 371 pt, and the longer tool names
// ("Screen Recording", "Window Backdrop") ended in an ellipsis there at the larger text sizes.

/// A short page title, and the five that need the most room.
private let titles = ["Home", "Crosshair", "Timer Overlay", "Screen Recording", "Window Backdrop", "Key Rebinder"]

/// The text sizes Settings offers, 90% to 130% in steps of 5.
private let textSizes = [0.9, 0.95, 1.0, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3]

/// The window's 680 pt minimum, less its 237 pt sidebar and the page's 36 pt margins; and the default 760 pt window.
private let narrowestColumn: CGFloat = 371
private let defaultColumn: CGFloat = 451

/// The title row's fixed parts: 16 pt on each side of the spacer, which is at least 16 pt itself.
private let rowGaps: CGFloat = 48

/// The size of a switch: 40 × 22 pt and 4 pt of padding all round.
private let switchSize = CGSize(width: 48, height: 30)

@Suite("Page title fit: the choice")
struct TitleFitChoiceTests {
    @Test func aTitleThatFitsStaysAtFullSize() {
        #expect(STTitleFit(lineWidth: 300, room: 300) == .full)
        #expect(STTitleFit(lineWidth: 300, room: 480) == .full)
    }

    @Test func aTitleShrinksOnlyWhenItMust() {
        #expect(STTitleFit(lineWidth: 300, room: 299.9) == .shrunk)
        #expect(STTitleFit(lineWidth: 300, room: 250) == .shrunk)
    }

    @Test func aTitleNeverShrinksBelowSeventyPercent() {
        #expect(STTitleFit.floor == 0.7)
        for width in [96.0, 262, 335, 436] {
            // 2% to spare over the floor's share: down to there it is one line, below it two.
            let least = width * 0.7 * 1.02
            #expect(STTitleFit(lineWidth: width, room: least) == .shrunk, "\(width) pt line in \(least) pt")
            #expect(STTitleFit(lineWidth: width, room: least - 0.01) == .wrapped, "\(width) pt line in \(least - 0.01) pt")
            #expect(STTitleFit(lineWidth: width, room: width * 0.5) == .wrapped)
            #expect(STTitleFit(lineWidth: width, room: 0) == .wrapped)
        }
    }

    @Test func aWrappedTitleIsAimedAboveTheFloorAndBelowFullSize() {
        #expect(STTitleFit.wrappedScale > STTitleFit.floor)
        #expect(STTitleFit.wrappedScale < 1)
    }
}

/// A window that reports a fixed backing scale, so a render doesn't change with the main display.
private final class FixedScaleWindow: NSWindow {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
    }

    override var backingScaleFactor: CGFloat { 2 }
}

/// The page header as it was before titles could shrink: the title on one line, cut off with an ellipsis where it doesn't fit.
private struct PlainHeader<Trailing: View>: View {
    private let title: String
    private let tagline: String
    private let trailing: Trailing
    @Environment(\.stTheme) private var theme

    init(title: String, tagline: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.tagline = tagline
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(title).stStyle(.pageTitle).foregroundStyle(STColor.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                trailing
            }
            STGiltRule().padding(.top, 6)
            Text(tagline).stStyle(.standfirst).foregroundStyle(theme.inkSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
    }
}

@MainActor
@Suite("Page title fit")
struct PageTitleFitTests {
    /// Under the rule: short enough to stay on one line at every width here, so it never changes the header's height.
    private static let tagline = "A tagline."

    /// The theme every header here is drawn in: Reduce animations on, so the gilt rule is there whole at once.
    private func theme(_ textScale: Double) -> STTheme {
        STTheme(textScale: textScale, motionMode: .reduced)
    }

    /// A title's width on one line, at full size.
    private func lineWidth(_ title: String, textScale: Double) -> CGFloat {
        hostingView(AnyView(Text(title).stStyle(.pageTitle).fixedSize().environment(\.stTheme, theme(textScale)))).fittingSize.width
    }

    /// The header `column` wide, as a bitmap at 2 pixels to the point.
    private func bitmap(_ header: some View, column: CGFloat, textScale: Double) -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = hostingView(AnyView(
            header.environment(\.stSoundPlayer, STSoundPlayer.silent).environment(\.stTheme, theme(textScale)).frame(width: column)
                .background(STColor.background)))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = CGSize(width: column, height: ceil(host.fittingSize.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = FixedScaleWindow(contentRect: host.frame)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    /// Whether two bitmaps hold the same pixels.
    private func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let da = a.bitmapData, let db = b.bitmapData else { return false }
        return (0..<a.pixelsHigh).allSatisfy { y in
            memcmp(da + y * a.bytesPerRow, db + y * b.bytesPerRow, a.pixelsWide * 4) == 0
        }
    }

    /// How tall the header is `column` wide, and where the red box that stands in for its switch ended up, in points.
    private func switchRow(_ title: String, column: CGFloat, textScale: Double) -> (height: CGFloat, switchBox: CGRect) {
        let rep = bitmap(
            STPageHeader(title: title, tagline: Self.tagline) {
                Color(red: 1, green: 0, blue: 0).frame(width: switchSize.width, height: switchSize.height)
            },
            column: column, textScale: textScale)
        var box = CGRect.null
        if let data = rep.bitmapData {
            for y in 0..<rep.pixelsHigh {
                let row = data + y * rep.bytesPerRow
                for x in 0..<rep.pixelsWide where row[x * 4] > 200 && row[x * 4 + 1] < 60 && row[x * 4 + 2] < 60 {
                    box = box.union(CGRect(x: Double(x) / 2, y: Double(y) / 2, width: 0.5, height: 0.5))
                }
            }
        }
        return (CGFloat(rep.pixelsHigh) / 2, box)
    }

    /// Where the title is one line the row is as tall as the title at full size, so a title that shrinks leaves the switch
    /// and everything under the header where they were. Only a title that wraps makes the header taller.
    @Test(arguments: titles, textSizes)
    func theSwitchStaysWhereItWasWhileTheTitleIsOnOneLine(title: String, textScale: Double) {
        let atFullSize = switchRow(title, column: 1_000, textScale: textScale)
        let narrow = switchRow(title, column: narrowestColumn, textScale: textScale)
        #expect(!narrow.switchBox.isNull && !atFullSize.switchBox.isNull, "the switch was drawn")
        #expect(abs(narrow.switchBox.maxX - narrowestColumn) <= 0.5, "the switch is at the column's right edge")
        // Where one line is chosen: room for the title at 0.7 of its size, with 2% to spare. The width measured here is whole
        // points, so a title within 2 pt of that choice may go either way.
        let room = narrowestColumn - rowGaps - switchSize.width
        let leastForOneLine = lineWidth(title, textScale: textScale) * STTitleFit.floor * STTitleFit.slack
        let context = "\(title) at \(textScale)x"
        if room >= leastForOneLine + 2 {
            #expect(narrow.height == atFullSize.height, "\(context): the header is \(narrow.height) pt, not \(atFullSize.height)")
            #expect(abs(narrow.switchBox.minY - atFullSize.switchBox.minY) <= 0.5,
                    "\(context): the switch is \(narrow.switchBox.minY) pt down, not \(atFullSize.switchBox.minY)")
        } else if room <= leastForOneLine - 2 {
            #expect(narrow.height > atFullSize.height, "\(context) wraps, so its header is taller: \(narrow.height) pt, against \(atFullSize.height) pt")
        }
    }

    /// Where every title fits, as the default window's column and the sizes up to 105% give it, the header is the plain one,
    /// pixel for pixel: shrinking and wrapping are for the titles that don't fit.
    @Test(arguments: titles, [0.9, 0.95, 1.0, 1.05])
    func aTitleThatFitsIsDrawnAsItAlwaysWas(title: String, textScale: Double) {
        #expect(lineWidth(title, textScale: textScale) <= defaultColumn - rowGaps - switchSize.width, "\(title) fits the default window")
        let plain = bitmap(
            PlainHeader(title: title, tagline: Self.tagline) { STSwitch(isOn: .constant(false), label: title) },
            column: defaultColumn, textScale: textScale)
        let fitted = bitmap(
            STPageHeader(title: title, tagline: Self.tagline) { STSwitch(isOn: .constant(false), label: title) },
            column: defaultColumn, textScale: textScale)
        #expect(same(plain, fitted), "\(title) at \(textScale)x in the default window is not drawn as it was")
    }

    /// With no control beside it, as on Home and Settings, the title has the whole row.
    @Test(arguments: ["Home", "Settings"], [1.0, 1.3])
    func aTitleWithNothingBesideItIsDrawnAsItAlwaysWas(title: String, textScale: Double) {
        let plain = bitmap(PlainHeader(title: title, tagline: Self.tagline) { EmptyView() }, column: narrowestColumn, textScale: textScale)
        let fitted = bitmap(STPageHeader(title: title, tagline: Self.tagline) { EmptyView() }, column: narrowestColumn, textScale: textScale)
        #expect(same(plain, fitted))
    }
}
