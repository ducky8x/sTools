import STDesign
import SwiftUI

/// Screen Recording's Quality row (spec 5.4.5): Automatic or Manual, and with Manual a slider for the percentage.
///
/// The slider sits beside the choice, as it always has, for as long as its track keeps its 80 pt there. A choice never gets
/// narrower than its words, so where that leaves the slider less (the window at its 680 pt minimum) the slider goes on a
/// line of its own under the choice, and neither word of the choice breaks inside itself.
struct RecordingQualityRow: View {
    @Binding var isManual: Bool
    /// The quality the slider shows and sets, from 10 to 100.
    @Binding var percent: Double

    var body: some View {
        // The first that fits at its ideal width, and a slider's ideal width is the least it needs.
        ViewThatFits(in: .horizontal) {
            beside
            under
        }
    }

    private var choice: some View {
        STSegmented(selection: $isManual, options: [.init(false, "Automatic"), .init(true, "Manual")])
    }

    private var slider: some View {
        STSlider(value: $percent, in: 10...100, label: "Quality", valueText: { "\(Int($0))%" })
    }

    /// The slider, then the choice, beside the label.
    private var beside: some View {
        STSettingsRow("Quality") {
            HStack(spacing: 12) {
                if isManual { slider }
                choice
            }
        }
    }

    /// The choice beside the label, as any other choice sits, and the slider on a line of its own under it, to the right
    /// like every control.
    private var under: some View {
        VStack(alignment: .trailing, spacing: 0) {
            STSettingsRow("Quality", showsRule: false, combinesForAccessibility: false) { choice.fixedSize() }
            if isManual { slider.labelsHidden().padding(.bottom, 12) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
        }
    }
}
