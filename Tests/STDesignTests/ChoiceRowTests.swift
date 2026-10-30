import AppKit
import SwiftUI
import Testing
@testable import STDesign

// A choice kept in view (`STSegmented`) sits beside its label while the options fit there, and under the label when they
// don't, so no option wraps or breaks. The control is NBB Overlay's Aspect ratio: Square · 4:3 · 16:9 · Ninjabrain Bot ·
// Custom, which wrapped at the introduction's default width and broke words at its narrowest.

@MainActor
@Suite("Choice row")
struct ChoiceRowTests {
    private static let label = "Aspect ratio"
    private static let titles = ["Square", "4:3", "16:9", "Ninjabrain Bot", "Custom"]

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

    // MARK: The switch between them

    @Test func theRowStacksExactlyWhenTheBesideLayoutNoLongerFits() {
        let needed = besideWidth
        let beside = fitting(choiceRow(), width: needed.rounded(.up) + 1).height
        let under = fitting(choiceRow(), width: needed.rounded(.down) - 1).height
        #expect(under > beside + 10)
        #expect(abs(beside - fitting(besideRow(), width: needed + 1).height) < 0.5)
    }
}
