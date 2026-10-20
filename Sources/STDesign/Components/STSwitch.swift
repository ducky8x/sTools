import SwiftUI

/// A slim pill switch: the knob springs across and the accent fill spreads out from it.
public struct STSwitch: View {
    @Binding private var isOn: Bool
    private let label: String

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 22
    private let knobInset: CGFloat = 3

    public init(isOn: Binding<Bool>, label: String) {
        _isOn = isOn
        self.label = label
    }

    public var body: some View {
        let knobDiameter = trackHeight - knobInset * 2
        let offCenter = knobInset + knobDiameter / 2
        let onCenter = trackWidth - offCenter
        let knobCenter = isOn ? onCenter : offCenter

        ZStack {
            Circle()
                .fill(theme.accentStroke)
                .frame(width: trackWidth * 2.2, height: trackWidth * 2.2)
                .scaleEffect(isOn ? 1 : 0.01)
                .offset(x: knobCenter - trackWidth / 2)
                .frame(width: trackWidth, height: trackHeight)
                .clipShape(Capsule())
            Capsule().strokeBorder(isOn ? theme.accentStroke : theme.stroke, lineWidth: 1.5)
            Circle()
                .fill(STColor.ink)
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(x: knobCenter - trackWidth / 2)
        }
        .frame(width: trackWidth, height: trackHeight)
        .stAnimation(STMotion.quick, value: isOn)
        .padding(4)
        .overlay {
            Capsule()
                .stroke(theme.accentStroke, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) { toggle(); return .handled }
        .onKeyPress(.return) { toggle(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction(.default, toggle)
    }

    private func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        sound.play(.click)
    }
}
