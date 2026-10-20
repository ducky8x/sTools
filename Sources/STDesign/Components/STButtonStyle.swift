import SwiftUI

/// The three button looks from the spec: primary (ink fill), secondary (stroke outline), quiet (accent text, draw-in underline).
public struct STButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, quiet }

    private let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        STButtonBody(kind: kind, configuration: configuration)
    }
}

private struct STButtonBody: View {
    let kind: STButtonStyle.Kind
    let configuration: ButtonStyleConfiguration

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovering = false

    private var showsUnderline: Bool { isEnabled && (isHovering || isFocused) }

    var body: some View {
        configuration.label
            .stStyle(.label)
            .foregroundStyle(labelColor)
            .offset(y: isHovering && isEnabled ? -1 : 0)
            .stAnimation(STMotion.press, value: isHovering)
            .padding(.horizontal, kind == .quiet ? 2 : 16)
            .padding(.vertical, kind == .quiet ? 3 : 8)
            .background { chrome }
            .overlay(alignment: .bottom) { if kind == .quiet { underline } }
            .overlay { focusRing }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .stAnimation(STMotion.press, value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
            .focusEffectDisabled()
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { sound.play(.click) }
            }
    }

    private var labelColor: Color {
        switch kind {
        case .primary: STColor.background
        case .secondary: STColor.ink
        case .quiet: theme.accent
        }
    }

    @ViewBuilder private var chrome: some View {
        switch kind {
        case .primary:
            RoundedRectangle(cornerRadius: 8).fill(STColor.ink)
        case .secondary:
            RoundedRectangle(cornerRadius: 8).strokeBorder(theme.stroke, lineWidth: 1.5)
        case .quiet:
            Color.clear
        }
    }

    private var underline: some View {
        Rectangle()
            .fill(theme.accent)
            .frame(height: 1)
            .scaleEffect(x: showsUnderline ? 1 : 0, anchor: .leading)
            .stAnimation(STMotion.quick, value: showsUnderline)
    }

    private var focusRing: some View {
        RoundedRectangle(cornerRadius: kind == .quiet ? 3 : 8)
            .stroke(theme.accentStroke, lineWidth: 2)
            .padding(-3)
            .opacity(isFocused && isEnabled ? 1 : 0)
    }
}
