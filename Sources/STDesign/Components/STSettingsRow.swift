import SwiftUI

/// One row of a tool page's settings: a small-caps label on the left, its control on the right,
/// and a `rule` hairline beneath. Label and control read as one accessibility element.
///
/// The row's label names the control, so the control's own visible label is hidden (`.labelsHidden()`);
/// `STSlider` honors this, and every control keeps its accessibility label.
public struct STSettingsRow<Control: View>: View {
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
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .stStyle(.label)
                .foregroundStyle(theme.inkSecondary)
            Spacer(minLength: 16)
            control.labelsHidden()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showsRule {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
