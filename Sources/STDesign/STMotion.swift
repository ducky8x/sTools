import SwiftUI

/// Motion tokens from spec section 3.4. The press scale (0.97) is applied by components.
public enum STMotion {
    public static let press: Animation = .easeOut(duration: 0.10)
    public static let quick: Animation = .spring(response: 0.26, dampingFraction: 0.82)
    public static let standard: Animation = .spring(response: 0.40, dampingFraction: 0.86)
    public static let page: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.50)
    public static let reducedFade: Animation = .easeInOut(duration: 0.2)
    public static let typeInterval: Duration = .milliseconds(18)
    public static let ceremony: Duration = .seconds(4)
    public static let staggerInterval: Duration = .milliseconds(35)
    public static let staggerMax = 10

    /// Reduce Motion turns every motion into a short crossfade.
    public static func resolve(_ animation: Animation, reduce: Bool) -> Animation { reduce ? reducedFade : animation }
}

public extension View {
    /// Like `.animation(_:value:)`, but honors the theme's Reduce Motion setting.
    func stAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(STAnimationModifier(animation: animation, value: value))
    }
}

private struct STAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.stTheme) private var theme
    func body(content: Content) -> some View {
        content.animation(STMotion.resolve(animation, reduce: theme.reduceMotion), value: value)
    }
}
