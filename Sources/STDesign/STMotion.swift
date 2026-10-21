import SwiftUI

/// Motion tokens from spec section 3.4. The press scale (0.97) is applied by components.
///
/// While motion is reduced (`STTheme.reduceMotion`: Settings ▸ Appearance ▸ Reduce animations, or macOS's Reduce
/// motion) nothing moves and every change happens at once: `resolve` and `stAnimation` give no animation, `animate`
/// makes its changes without one, and `stMotionRoot` at the root of each window strips any animation still asked for.
public enum STMotion {
    public static let press: Animation = .easeOut(duration: 0.10)
    public static let quick: Animation = .spring(response: 0.26, dampingFraction: 0.82)
    public static let standard: Animation = .spring(response: 0.40, dampingFraction: 0.86)
    public static let page: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.50)
    public static let typeInterval: Duration = .milliseconds(18)
    public static let ceremony: Duration = .seconds(4)
    public static let staggerInterval: Duration = .milliseconds(35)
    public static let staggerMax = 10

    /// `animation`, or none while motion is reduced.
    public static func resolve(_ animation: Animation, reduce: Bool) -> Animation? { reduce ? nil : animation }

    /// A transaction with every animation off, including the ones `.animation(_:value:)` would add beneath it.
    public static var instant: Transaction {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return transaction
    }

    /// Makes `changes` with `animation`, or at once with every animation off while motion is reduced.
    @MainActor @discardableResult
    public static func animate<Result>(_ animation: Animation, reduce: Bool, _ changes: () throws -> Result) rethrows -> Result {
        reduce ? try withTransaction(instant, changes) : try withAnimation(animation, changes)
    }

    /// Like `animate(_:reduce:_:)`, then `completion` once the animation is over: at once while motion is reduced,
    /// because SwiftUI never calls the completion of an animation that `stMotionRoot` took away.
    @MainActor
    public static func animate(_ animation: Animation, reduce: Bool, _ changes: () -> Void, completion: @escaping () -> Void) {
        guard !reduce else {
            withTransaction(instant, changes)
            completion()
            return
        }
        withAnimation(animation, changes, completion: completion)
    }
}

public extension View {
    /// Like `.animation(_:value:)`, but with no animation while the theme reduces motion.
    func stAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(STAnimationModifier(animation: animation, value: value))
    }

    /// Goes once at the root of every window and panel: while `theme` reduces motion, no animation or transition plays
    /// anywhere beneath, whoever asked for it. Each change is read as it happens, so switching applies at once.
    func stMotionRoot(_ theme: STTheme) -> some View {
        transaction { transaction in
            guard theme.reduceMotion else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
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
