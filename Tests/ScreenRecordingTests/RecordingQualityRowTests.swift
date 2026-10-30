import AppKit
import STDesign
import SwiftUI
import Testing
@testable import ScreenRecording

// The Quality row's choice keeps its words whole. With Manual chosen its slider sat beside the choice at every width, and in
// the 680 pt window's 371 pt column there was no room for both: "Automatic" and "Manual" broke inside themselves ("AUTO /
// MATI / C", "MAN / UAL"), and the row was 88 pt tall. The slider now stays beside the choice while its track keeps 80 pt
// there, as in the default window, and goes on a line of its own under the choice when it can't, so the row is one of two
// shapes, each of a height that follows from its parts, and never a third with a broken word.

@MainActor
@Suite("Recording quality row")
struct RecordingQualityRowTests {
    /// The window's 680 pt minimum, less its 237 pt sidebar and the page's two 36 pt margins.
    private static let narrowestColumn: CGFloat = 371
    /// The window's default 760 pt, less the same.
    private static let defaultColumn: CGFloat = 451

    private func hosted<V: View>(_ view: V, width: CGFloat? = nil, textScale: Double = 1) -> NSHostingView<AnyView> {
        _ = NSApplication.shared
        _ = STFont.register()
        let themed = view.environment(\.stSoundPlayer, STSoundPlayer.silent).environment(\.stTheme, STTheme(textScale: textScale))
        return NSHostingView(rootView: width.map { AnyView(themed.frame(width: $0)) } ?? AnyView(themed))
    }

    private func size<V: View>(_ view: V, width: CGFloat? = nil, textScale: Double = 1) -> CGSize {
        hosted(view, width: width, textScale: textScale).fittingSize
    }

    private func row(manual: Bool) -> RecordingQualityRow {
        RecordingQualityRow(isManual: .constant(manual), percent: .constant(70))
    }

    private var choice: some View {
        STSegmented(selection: .constant(true), options: [.init(false, "Automatic"), .init(true, "Manual")])
    }

    private var slider: some View {
        STSlider(value: .constant(70), in: 10...100, label: "Quality", valueText: { "\(Int($0))%" }).labelsHidden()
    }

    /// The row with the choice on one line beside the label: a settings row's 12 pt above and below its tallest control.
    private func besideHeight(textScale: Double = 1) -> CGFloat {
        12 + max(size(choice, textScale: textScale).height, size(slider, textScale: textScale).height) + 12
    }

    /// The choice beside the label, then the slider on a line of its own.
    private func underHeight(textScale: Double = 1) -> CGFloat {
        12 + size(choice, textScale: textScale).height + 12 + size(slider, textScale: textScale).height + 12
    }

    @Test func inTheNarrowestWindowTheSliderGoesUnderTheChoice() {
        let height = size(row(manual: true), width: Self.narrowestColumn).height
        #expect(abs(height - underHeight()) < 1, "\(height) pt: not the choice over the slider (\(underHeight()) pt), so a word broke")
    }

    @Test func inTheDefaultWindowTheSliderStaysBesideTheChoice() {
        let height = size(row(manual: true), width: Self.defaultColumn).height
        #expect(abs(height - besideHeight()) < 1, "\(height) pt, not one line (\(besideHeight()) pt)")
    }

    /// The row is beside exactly while the slider keeps the least its track needs there, and under from the width where it
    /// can't.
    @Test func theSliderMovesUnderTheChoiceExactlyWhenItsTrackWouldHaveToGiveWayTooFar() {
        let least = NSHostingController(rootView: AnyView(slider.environment(\.stSoundPlayer, STSoundPlayer.silent)))
            .sizeThatFits(in: CGSize(width: 0, height: 1_000)).width
        let needed = size(STSettingsRow("Quality") { HStack(spacing: 12) { slider.frame(width: least); choice } }).width
        #expect(needed > 400 && needed < Self.defaultColumn, "\(needed) pt: the default window has room for it")
        let beside = size(row(manual: true), width: needed.rounded(.up) + 1).height
        let under = size(row(manual: true), width: needed.rounded(.down) - 1).height
        #expect(abs(beside - besideHeight()) < 1, "\(beside) pt with room for the slider's least")
        #expect(abs(under - underHeight()) < 1, "\(under) pt a hair short of it")
    }

    @Test(arguments: [371.0, 451.0])
    func withAutomaticTheChoiceStaysBesideItsLabel(column: CGFloat) {
        let height = size(row(manual: false), width: column).height
        #expect(abs(height - (12 + size(choice).height + 12)) < 1, "\(height) pt in \(column) pt")
    }

    /// Whatever the text size and the column, the row is one of its two shapes. Squeezed, as it was, the choice wraps and
    /// the row is a third height.
    @Test(arguments: [1.0, 1.1, 1.3], [371.0, 400, 451, 520, 600])
    func theRowIsAlwaysBesideOrUnderNeverSqueezed(textScale: Double, column: CGFloat) {
        let height = size(row(manual: true), width: column, textScale: textScale).height
        let shapes = [besideHeight(textScale: textScale), underHeight(textScale: textScale)]
        #expect(shapes.contains { abs(height - $0) < 1 }, "\(height) pt at \(textScale)x in \(column) pt, not \(shapes)")
    }
}
