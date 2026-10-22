import CoreGraphics
import Foundation
import STDesign
import SwiftUI

/// What the overlay's motion does (spec 5.6.4, 3.4): its pop-in and pop-out in each Pop-up motion, and its pulse or
/// flash in each While ringing setting. Pure values; the presenter plays them through `STMotion`.
///
/// Motion moves the whole plate and nothing else: its scale, its offset and its opacity. The digits never animate.
/// While motion is reduced (Reduce animations, or macOS's Reduce motion) nothing moves at all: every step starts and
/// ends at rest with no animation, so the overlay appears and leaves at once and never pulses or flashes.
public enum TimerMotion {
    /// How the plate is drawn at one moment of a motion.
    public struct Pose: Equatable, Sendable {
        public var scale: CGFloat
        /// Points from where the plate sits, as SwiftUI draws: +x right, +y down.
        public var offset: CGSize
        public var opacity: Double

        public init(scale: CGFloat = 1, offset: CGSize = .zero, opacity: Double = 1) {
            self.scale = scale
            self.offset = offset
            self.opacity = opacity
        }

        /// Where the plate sits between motions: full size, in place and opaque.
        public static let rest = Pose()
    }

    /// One move of the plate from `from` to `to`.
    public struct Step: Equatable, Sendable {
        public var from: Pose
        public var to: Pose
        /// The `STMotion` token that plays it, or nil when it happens at once.
        public var animation: Animation?
        /// About how long `animation` takes to finish, in seconds; 0 at once.
        public var duration: TimeInterval

        public init(from: Pose, to: Pose, animation: Animation?, duration: TimeInterval) {
            self.from = from
            self.to = to
            self.animation = animation
            self.duration = animation == nil ? 0 : duration
        }

        /// Whether the step moves nothing.
        public var isStill: Bool { from == to }

        /// Staying at `pose`, at once.
        public static func still(_ pose: Pose = .rest) -> Step {
            Step(from: pose, to: pose, animation: nil, duration: 0)
        }
    }

    /// The spring pop's starting scale: the plate grows from about 0.9 (spec 5.6.4).
    public static let popScale: CGFloat = 0.9
    /// The peak of a ring's pulse: 1 → 1.06 → 1 (spec 5.6.4).
    public static let pulseScale: CGFloat = 1.06
    /// How far a slide travels, toward or from the nearest display edge. Short, so the panel stays small.
    public static let slideDistance: CGFloat = 24
    /// A quick flash's dip.
    public static let flashOpacity: Double = 0.25
    /// The least time between two flashes' starts, so no second ever holds more than 3 (WCAG 2.3.1).
    public static let minimumFlashInterval: TimeInterval = 1.0 / 3

    /// How the overlay comes in, ending at rest. `edge` is the display edge nearest the plate, which a slide comes
    /// from.
    public static func popIn(_ motion: TimerOverlaySettings.PopUpMotion, from edge: Edge, reduceMotion: Bool) -> Step {
        guard !reduceMotion, let away = awayPose(motion, edge: edge) else { return .still() }
        let token = token(for: motion)
        return Step(from: away, to: .rest, animation: token.animation, duration: token.duration)
    }

    /// How the overlay leaves: the pop-in reversed.
    public static func popOut(_ motion: TimerOverlaySettings.PopUpMotion, toward edge: Edge, reduceMotion: Bool) -> Step {
        guard !reduceMotion, let away = awayPose(motion, edge: edge) else { return .still() }
        let token = token(for: motion)
        return Step(from: .rest, to: away, animation: token.animation, duration: token.duration)
    }

    /// What one ring does to the plate, played in order: a pulse there and back, or one quick flash. Empty for the
    /// time's-up look alone, and always while motion is reduced, when the time's-up look holds.
    public static func ring(_ whileRinging: TimerOverlaySettings.WhileRinging, reduceMotion: Bool) -> [Step] {
        guard !reduceMotion else { return [] }
        switch whileRinging {
        case .pulsePerRing:
            let peak = Pose(scale: pulseScale)
            return [Step(from: .rest, to: peak, animation: Token.press.animation, duration: Token.press.duration),
                    Step(from: peak, to: .rest, animation: Token.quick.animation, duration: Token.quick.duration)]
        case .quickFlashes:
            let dip = Pose(opacity: flashOpacity)
            return [Step(from: .rest, to: dip, animation: Token.press.animation, duration: Token.press.duration),
                    Step(from: dip, to: .rest, animation: Token.press.animation, duration: Token.press.duration)]
        case .timesUpLookOnly:
            return []
        }
    }

    /// The display edge closest to the plate (AppKit coordinates), which a slide comes in from. A tie goes to the
    /// top, then the bottom, the leading and the trailing edge.
    public static func nearestEdge(of plate: CGRect, in display: CGRect) -> Edge {
        let gaps: [(Edge, CGFloat)] = [
            (.top, display.maxY - plate.maxY), (.bottom, plate.minY - display.minY),
            (.leading, plate.minX - display.minX), (.trailing, display.maxX - plate.maxX),
        ]
        var nearest = gaps[0]
        for gap in gaps.dropFirst() where gap.1 < nearest.1 { nearest = gap }
        return nearest.0
    }

    /// The room kept around the plate inside its panel, in whole points, so a slide, the spring pop and a pulse all
    /// stay inside the panel while it covers no more than the plate needs.
    public static func margin(around plateSize: CGSize) -> CGFloat {
        let pulseGrowth = (pulseScale - 1) / 2 * max(plateSize.width, plateSize.height)
        return (max(slideDistance, pulseGrowth) + 2).rounded(.up)
    }

    // MARK: - Private

    /// The pose a pop-in starts from and a pop-out ends at; nil when the overlay simply appears.
    private static func awayPose(_ motion: TimerOverlaySettings.PopUpMotion, edge: Edge) -> Pose? {
        switch motion {
        case .springPop: Pose(scale: popScale, opacity: 0)
        case .fade: Pose(opacity: 0)
        case .slide: Pose(offset: slideOffset(from: edge), opacity: 0)
        case .instant: nil
        }
    }

    private static func slideOffset(from edge: Edge) -> CGSize {
        switch edge {
        case .top: CGSize(width: 0, height: -slideDistance)
        case .bottom: CGSize(width: 0, height: slideDistance)
        case .leading: CGSize(width: -slideDistance, height: 0)
        case .trailing: CGSize(width: slideDistance, height: 0)
        }
    }

    private static func token(for motion: TimerOverlaySettings.PopUpMotion) -> Token {
        motion == .slide ? .standard : .quick
    }

    /// The `STMotion` tokens the overlay uses, with about how long each takes to settle.
    private enum Token {
        case press, quick, standard

        var animation: Animation {
            switch self {
            case .press: STMotion.press
            case .quick: STMotion.quick
            case .standard: STMotion.standard
            }
        }

        var duration: TimeInterval {
            switch self {
            case .press: 0.10
            case .quick: 0.30
            case .standard: 0.45
            }
        }
    }
}
