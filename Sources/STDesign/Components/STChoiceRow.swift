import SwiftUI

/// A settings row for a choice kept in view (`STSegmented`): the small-caps label with every option beside it, as
/// `STSettingsRow` lays it out, or the options under the label when the column is too narrow for both on one line, and
/// on a second line, a whole option at a time, when even that is too narrow for them (a window at its minimum width, a
/// long set of options). A segmented control never gets narrower than its words, so without this its options wrap to a
/// second line or break inside a word. Either way VoiceOver finds a group named by the label and reads each option in
/// it, the chosen one selected, instead of one element that runs every option together.
public struct STChoiceRow<Control: View>: View {
    private let label: String
    private let showsRule: Bool
    private let control: Control
    @Environment(\.stTheme) private var theme

    public init(_ label: String, showsRule: Bool = true, @ViewBuilder control: () -> Control) {
        self.label = label
        self.showsRule = showsRule
        self.control = control()
    }

    public var body: some View {
        // The first that fits: beside the label, under it, or under it with the options wrapping between options, which
        // takes any width.
        ViewThatFits(in: .horizontal) {
            STSettingsRow(label, showsRule: showsRule, combinesForAccessibility: false) { control.fixedSize() }
            underTheLabel
            underTheLabel.environment(\.stSegmentedWraps, true)
        }
    }

    private var underTheLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .stStyle(.label)
                .foregroundStyle(theme.inkSecondary)
                .accessibilityHidden(true)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showsRule {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
        }
        // A group named by the label, its options read one by one, as the settings row keeps them.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
