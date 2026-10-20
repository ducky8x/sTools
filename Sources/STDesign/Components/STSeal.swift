import SwiftUI

/// A small gold seal with a check mark. When `isStamped` becomes true it stamps in: scale 1.15
/// to 1 with one soft bounce, and the stamp sound. While false it is invisible but keeps its
/// size so layout does not jump. With Reduce Motion it fades in over 0.2 s.
public struct STSeal: View {
    private let isStamped: Bool

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sounds

    public init(isStamped: Bool) {
        self.isStamped = isStamped
    }

    public var body: some View {
        let diameter = 22 * theme.textScale
        Circle()
            .fill(theme.accent)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: 11 * theme.textScale, weight: .bold))
                    .foregroundStyle(STColor.background)
            }
            .scaleEffect(theme.reduceMotion || isStamped ? 1 : 1.15)
            .opacity(isStamped ? 1 : 0)
            .stAnimation(STMotion.quick, value: isStamped)
            .onChange(of: isStamped) { _, stamped in
                if stamped { sounds.play(.stamp) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Done")
            .accessibilityHidden(!isStamped)
    }
}
