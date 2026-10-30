import AppKit
import SwiftUI
import Testing
@testable import STDesign

// A choice kept in view (`STSegmented`) sits beside its label while the options fit there, under the label when they
// don't, and on a second line, a whole option at a time, when even that is too narrow, so no option wraps or breaks inside
// a word. The controls: NBB Overlay's Aspect ratio (Square · 4:3 · 16:9 · Ninjabrain Bot · Custom), which wrapped at the
// introduction's default width and broke words at its narrowest, Timer Overlay's Look, which wrapped at the narrowest,
// and Crosshair's Image anchor, which broke words there.

@MainActor
@Suite("Choice row")
struct ChoiceRowTests {
    private static let label = "Aspect ratio"
    private static let titles = ["Square", "4:3", "16:9", "Ninjabrain Bot", "Custom"]
    /// Timer Overlay's Look: "sTools plate" wrapped onto two lines beside the label at the 680 pt window's width.
    private static let looks = ["sTools plate", "Digits only", "Compact pill"]
    /// Crosshair's Image anchor: five long options, which don't fit on one line in the 680 pt window's column (371 pt),
    /// even under the label.
    private static let anchors = ["Center", "Top left", "Top right", "Bottom left", "Bottom right"]

    /// The five options, each in one line.
    private struct Options: View {
        let titles: [String]
        @State private var selection = 3

        var body: some View {
            STSegmented(selection: $selection, options: titles.enumerated().map { STSegmentedOption($0.offset, $0.element) })
        }
    }

    private func options(_ titles: [String] = ChoiceRowTests.titles) -> Options { Options(titles: titles) }

    /// The size a view takes when it is offered `width` and as much height as it wants.
    private func fitting<V: View>(_ view: V, width: CGFloat? = nil) -> CGSize {
        let sized = width.map { AnyView(view.frame(width: $0)) } ?? AnyView(view)
        return hostingView(sized.environment(\.stSoundPlayer, STSoundPlayer.silent)).fittingSize
    }

    private func choiceRow(_ titles: [String] = ChoiceRowTests.titles) -> some View {
        STChoiceRow(Self.label) { options(titles) }
    }

    /// The row as the app lays every other settings row out: the label, then the options at the right.
    private func besideRow(_ titles: [String] = ChoiceRowTests.titles) -> some View {
        STSettingsRow(Self.label, combinesForAccessibility: false) { options(titles).fixedSize() }
    }

    /// The width the label and every option need on one line: the narrowest the beside layout fits.
    private var besideWidth: CGFloat { fitting(besideRow()).width }

    // MARK: Beside the label

    @Test func theOptionsSitBesideTheLabelWhenTheyFit() {
        let room = besideWidth + 1
        #expect(abs(fitting(choiceRow(), width: room).height - fitting(besideRow(), width: room).height) < 0.5)
        #expect(abs(fitting(choiceRow(), width: 1_000).height - fitting(besideRow(), width: 1_000).height) < 0.5)
    }

    @Test func aShortChoiceStaysBesideItsLabelInANarrowColumn() {
        let titles = ["On", "Off"]
        #expect(abs(fitting(choiceRow(titles), width: 300).height - fitting(besideRow(titles), width: 300).height) < 0.5)
    }

    // MARK: Under the label

    /// Under the label the options keep one line each: the row is the label, a gap and the options at their own size.
    @Test(arguments: [453.0, 440, 373])
    func theOptionsMoveUnderTheLabelWhenTheyWouldWrap(width: CGFloat) {
        let labelHeight = fitting(Text(Self.label).stStyle(.label), width: width).height
        let optionsHeight = fitting(options().fixedSize()).height
        let expected = 12 + labelHeight + 4 + optionsHeight + 12
        let height = fitting(choiceRow(), width: width).height
        #expect(abs(height - expected) < 1, "\(height) pt, not the label over one line of options (\(expected) pt)")
        #expect(height > fitting(besideRow(), width: besideWidth + 1).height + 10, "taller than the beside row")
    }

    /// The control: laid out beside its label, as `STSettingsRow` does, the same options wrap in those widths, which is
    /// what the row avoids.
    @Test(arguments: [453.0, 373])
    func besideTheLabelTheOptionsWouldWrapThere(width: CGFloat) {
        let oneLine = fitting(besideRow(), width: besideWidth + 1).height
        let squeezed = fitting(STSettingsRow(Self.label, combinesForAccessibility: false) { options() }, width: width).height
        #expect(squeezed > oneLine + 10, "an option wraps to a second line")
    }

    /// The introduction's Timer trial and the Timer page at the 680 pt window: the column is 373 and 371 pt, and "sTools
    /// plate" wrapped beside the label. Under it, each option keeps one line.
    @Test(arguments: [373.0, 371])
    func timerOverlaysLookKeepsEachOptionOnOneLine(width: CGFloat) {
        let look = "Look"
        let labelHeight = fitting(Text(look).stStyle(.label), width: width).height
        let oneLine = fitting(options(Self.looks).fixedSize()).height
        let expected = 12 + labelHeight + 4 + oneLine + 12
        let row = fitting(STChoiceRow(look) { options(Self.looks) }, width: width).height
        #expect(abs(row - expected) < 1, "\(row) pt, not the label over one line of options (\(expected) pt)")
        let beside = fitting(STSettingsRow(look, combinesForAccessibility: false) { options(Self.looks) }, width: width).height
        #expect(beside > oneLine + 10, "control: in a plain settings row an option wraps at this width")
    }

    // MARK: Wrapping between options

    /// What one line of the options takes, and what a second line adds: a whole option's height and the gap between lines.
    private var oneLineOfOptions: CGFloat { fitting(options(Self.anchors).fixedSize()).height }
    private var secondLine: CGFloat {
        let option = fitting(STSegmented(selection: .constant(0), options: [STSegmentedOption(0, "Center")])).height
        return option - 8 + STSegmentedLayout.lineSpacing
    }

    /// Options too long for the column even under the label (Crosshair's Image anchor at the 680 pt window's 371 pt)
    /// wrap onto a second line a whole option at a time, so none squeezes or breaks inside a word.
    @Test(arguments: [373.0, 371])
    func optionsTooLongForTheColumnWrapBetweenOptions(width: CGFloat) {
        let labelHeight = fitting(Text(Self.label).stStyle(.label), width: width).height
        let twoLines = 12 + labelHeight + 4 + oneLineOfOptions + secondLine + 12
        let height = fitting(choiceRow(Self.anchors), width: width).height
        #expect(abs(height - twoLines) < 1, "\(height) pt, not the label over two lines of whole options (\(twoLines) pt)")
        #expect(fitting(options(Self.anchors).fixedSize()).width > width, "on one line they are wider than the column")
    }

    /// Each step is taken only when the one before doesn't fit: beside the label, under it on one line, under it on two.
    @Test func theOptionsWrapOnlyWhereOneLineWouldNotFit() {
        let oneLine = fitting(options(Self.anchors).fixedSize()).width
        let labelHeight = fitting(Text(Self.label).stStyle(.label), width: oneLine).height
        let single = 12 + labelHeight + 4 + oneLineOfOptions + 12
        #expect(abs(fitting(choiceRow(Self.anchors), width: oneLine + 1).height - single) < 1, "room for one line: one line")
        #expect(abs(fitting(choiceRow(Self.anchors), width: oneLine - 1).height - (single + secondLine)) < 1, "a hair short: two")
    }

    // MARK: The switch between them

    @Test func theRowStacksExactlyWhenTheBesideLayoutNoLongerFits() {
        let needed = besideWidth
        let beside = fitting(choiceRow(), width: needed.rounded(.up) + 1).height
        let under = fitting(choiceRow(), width: needed.rounded(.down) - 1).height
        #expect(under > beside + 10)
        #expect(abs(beside - fitting(besideRow(), width: needed + 1).height) < 0.5)
    }
}
