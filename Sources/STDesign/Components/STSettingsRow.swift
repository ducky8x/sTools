import SwiftUI

/// One row of a tool page's settings: a small-caps label on the left, its control on the right,
/// and a `rule` hairline beneath. Label and control read as one accessibility element, unless the row keeps its
/// control's elements apart (`combinesForAccessibility: false`): then VoiceOver finds a group named by the label and
/// moves through the control's own elements in it, as a row of options (`STSegmented`) needs, each one read with
/// whether it's chosen.
///
/// The row's label names the control, so the control's own visible label is hidden (`.labelsHidden()`);
/// `STSlider` honors this, and every control keeps its accessibility label.
public struct STSettingsRow<Control: View>: View {
    private let label: String
    private let showsRule: Bool
    private let combinesForAccessibility: Bool
    private let control: Control

    @Environment(\.stTheme) private var theme

    public init(_ label: String, showsRule: Bool = true, combinesForAccessibility: Bool = true,
                @ViewBuilder control: () -> Control) {
        self.label = label
        self.showsRule = showsRule
        self.combinesForAccessibility = combinesForAccessibility
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .stStyle(.label)
                .foregroundStyle(theme.inkSecondary)
                .accessibilityHidden(!combinesForAccessibility)
            Spacer(minLength: 16)
            control.labelsHidden()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showsRule {
                Rectangle().fill(STColor.rule).frame(height: 1).accessibilityHidden(true)
            }
        }
        .stSettingsRowAccessibility(label: label, combines: combinesForAccessibility)
    }
}

private extension View {
    /// A settings row's accessibility: one element combining label and control, or a group named `label` that keeps
    /// the control's elements apart.
    @ViewBuilder
    func stSettingsRowAccessibility(label: String, combines: Bool) -> some View {
        if combines {
            accessibilityElement(children: .combine)
        } else {
            accessibilityElement(children: .contain).accessibilityLabel(label)
        }
    }
}
