import SwiftUI

/// A `surface` band that says what is missing and offers the one action that fixes it: a leading
/// mark (`danger` for an error, accent for a warning), one sentence, one quiet button.
/// VoiceOver reads it as a single element and exposes the action on it.
public struct STRequirementStrip: View {
    public enum Kind: Sendable {
        case warning, error
    }

    private let kind: Kind
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    @Environment(\.stTheme) private var theme

    public init(kind: Kind, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    private var markName: String {
        kind == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var markColor: Color {
        kind == .error ? STColor.danger : theme.accent
    }

    private var kindWord: String {
        kind == .error ? "Error" : "Warning"
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: markName)
                .font(.system(size: 14 * theme.textScale))
                .foregroundStyle(markColor)
                .accessibilityHidden(true)
            Text(message)
                .stStyle(.body)
                .foregroundStyle(STColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if let actionTitle, let action {
                STStripActionButton(title: actionTitle, action: action)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(STColor.surface, in: shape)
        .overlay { shape.strokeBorder(STColor.rule, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kindWord): \(message)")
        .accessibilityActions {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}

/// The quiet button: accent text with an underline that draws in on hover and focus, a 1 pt lift
/// on hover and a press dip.
private struct STStripActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(STQuietActionStyle())
        .focusEffectDisabled()
    }
}

private struct STQuietActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        STQuietActionLabel(configuration: configuration)
    }
}

private struct STQuietActionLabel: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.stTheme) private var theme
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    private var showsUnderline: Bool { isHovering || isFocused }

    var body: some View {
        configuration.label
            .stStyle(.body)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(height: 1)
                    .scaleEffect(x: showsUnderline ? 1 : 0, anchor: .leading)
                    .padding(.horizontal, 4)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.accentStroke, lineWidth: 1.5)
                }
            }
            .offset(y: isHovering ? -1 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .stAnimation(STMotion.press, value: configuration.isPressed)
            .stAnimation(STMotion.quick, value: showsUnderline)
            .onHover { isHovering = $0 }
            .contentShape(Rectangle())
    }
}
