import SwiftUI

/// "Advanced" in small caps with a chevron; expands and collapses its content with `standard` (at once while motion
/// is reduced).
/// Built on `DisclosureGroup`, so it keeps the disclosure semantics of the system control.
public struct STAdvancedDisclosure<Content: View>: View {
    @Binding private var isExpanded: Bool
    private let content: Content

    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isExpanded = isExpanded
        self.content = content()
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Text("Advanced")
        }
        .disclosureGroupStyle(STDisclosureStyle())
    }
}

private struct STDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        STDisclosureBody(configuration: configuration)
    }
}

private struct STDisclosureBody: View {
    let configuration: DisclosureGroupStyleConfiguration

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                sound.play(.click)
                STMotion.animate(STMotion.standard, reduce: theme.reduceMotion) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                        .stStyle(.label)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(theme.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows or hides advanced settings")

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
