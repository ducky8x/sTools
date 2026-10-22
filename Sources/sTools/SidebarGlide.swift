import AppKit
import STDesign
import SwiftUI

/// The sounds of the sidebar's selection marker as it glides from row to row (spec 3.4): one glide whose length
/// follows how far, and so how fast, the marker travels, and one detent each time the marker's center crosses the
/// center of a row it passes over, timed by the marker's own spring.
enum SidebarGlide {
    /// The marker's spring: the app's `standard` motion (response 0.40 s, damping 0.86). The sidebar animates with
    /// `markerAnimation`, so the detents follow the curve the marker actually takes.
    static let spring = Spring(response: 0.40, dampingRatio: 0.86)
    static let markerAnimation: Animation = .spring(spring)

    /// Rows top to bottom, as the sidebar lists them.
    static let order: [Route] = [.home] + ToolID.allCases.map(Route.tool) + [.settings]

    /// Moves shorter than this, in points, play the short glide: at the default text size, a tool's neighbor
    /// (56 pt), Home to the first tool (66.5 pt), or the last tool to Settings in a window of the default height.
    static let shortTravel: CGFloat = 100
    /// Moves shorter than this play the medium glide (two or three rows); longer ones play the long glide.
    static let mediumTravel: CGFloat = 200

    /// The glide for a move of `travel` points.
    static func glide(forTravel travel: CGFloat) -> STSound {
        switch abs(travel) {
        case ..<shortTravel: .glideShort
        case ..<mediumTravel: .glideMedium
        default: .glideLong
        }
    }

    /// Where the marker is and how fast it moves, along the sidebar, in points and points per second.
    struct Motion: Equatable {
        var position: CGFloat
        var velocity: CGFloat = 0
    }

    /// One move's sounds: the glide to play at once and the detents, in seconds from the move's start.
    struct Plan: Equatable {
        var glide: STSound
        var detents: [TimeInterval]
    }

    /// The step of the search for crossings; each crossing is then placed between two steps.
    private static let step: TimeInterval = 0.001

    /// The sounds for the marker moving from `motion` to the row centered at `target`, past the rows centered at
    /// `rows` (every row but the destination). The marker follows `spring` from its position with its velocity, as
    /// SwiftUI retargets a spring that's interrupted mid-flight, so a move begun mid-glide is timed from where the
    /// marker really is. A detent marks each time the marker's center crosses a row's center; starting on a row's
    /// center isn't a crossing.
    static func plan(from motion: Motion, to target: CGFloat, passing rows: [CGFloat]) -> Plan {
        let travel = target - motion.position
        let glide = glide(forTravel: travel)
        let duration = spring.settlingDuration(target: Double(travel), initialVelocity: Double(motion.velocity),
                                               epsilon: 0.01)
        var detents: [TimeInterval] = []
        var previous = Double(motion.position)
        var time = 0.0
        while time < duration {
            let next = time + step
            let position = Double(motion.position) + spring.value(target: Double(travel),
                                                                 initialVelocity: Double(motion.velocity), time: next)
            for row in rows.map(Double.init) where (previous - row) * (position - row) < 0
                || (previous != row && position == row) {
                // Linear between the two steps: well under a millisecond off.
                detents.append(time + step * (row - previous) / (position - previous))
            }
            previous = position
            time = next
        }
        return Plan(glide: glide, detents: detents.sorted())
    }

    /// Where the marker is `elapsed` seconds into a move from `motion` to `target`, or nil once it has settled.
    static func motion(from motion: Motion, to target: CGFloat, after elapsed: TimeInterval) -> Motion? {
        let travel = Double(target - motion.position)
        let velocity = Double(motion.velocity)
        guard elapsed < spring.settlingDuration(target: travel, initialVelocity: velocity, epsilon: 0.01) else {
            return nil
        }
        return Motion(
            position: motion.position + spring.value(target: travel, initialVelocity: velocity, time: elapsed),
            velocity: spring.velocity(target: travel, initialVelocity: velocity, time: elapsed))
    }
}

/// The sidebar's rows' vertical centers, in points, as the sidebar last laid them out. Until it has, the layout at
/// the default text size in a window of the default height: the first tool 66.5 pt below Home, the tools 56 pt
/// apart, and Settings 96.5 pt below the last tool.
struct SidebarLayout: Equatable {
    var centers: [Route: CGFloat] = [:]

    func center(of route: Route) -> CGFloat {
        if let measured = centers[route] { return measured }
        switch route {
        case .home: return 0
        case .tool(let tool): return 66.5 + 56 * CGFloat(ToolID.allCases.firstIndex(of: tool) ?? 0)
        case .settings: return 66.5 + 56 * CGFloat(ToolID.allCases.count - 1) + 96.5
        }
    }
}

/// What the glide needs from the UI sound player; tests pass a fake that records instead of playing.
@MainActor protocol SidebarSoundPlaying: AnyObject {
    var isAudible: Bool { get }
    func play(_ sound: STSound)
}

extension STSoundPlayer: SidebarSoundPlaying {}

/// A one-shot timer for a detent; cancelling it before it fires means it never does.
@MainActor protocol SidebarGlideTimer: AnyObject {
    func cancel()
}

/// The time and one-shot timers the glide runs on; tests pass a fake clock they move by hand.
@MainActor protocol SidebarGlideClock: AnyObject {
    /// Seconds on a steady clock.
    var now: TimeInterval { get }
    /// Runs `action` once, `delay` seconds from now, unless the returned timer is cancelled first.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SidebarGlideTimer
}

/// One-shot dispatch timers on the main queue, with a millisecond's leeway so detents land where they should.
@MainActor final class DispatchGlideClock: SidebarGlideClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SidebarGlideTimer {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + max(delay, 0), leeway: .milliseconds(1))
        // One-shot: the source cancels itself once it has fired, which also lets it go.
        source.setEventHandler {
            MainActor.assumeIsolated { action() }
            source.cancel()
        }
        source.resume()
        return DispatchGlideTimer(source: source)
    }
}

@MainActor private final class DispatchGlideTimer: SidebarGlideTimer {
    private let source: any DispatchSourceTimer
    init(source: any DispatchSourceTimer) { self.source = source }
    func cancel() { source.cancel() }
}

/// Plays the sidebar's glide and detents for each move of the selection marker.
///
/// A move plays its glide at once and schedules a one-shot timer per detent; a new move cancels the timers still
/// pending, so its glide replaces the old one. Nothing is scheduled between moves. While motion is reduced the
/// marker jumps, so a move plays only the short glide. While UI sounds are off (or at volume 0, or off in macOS)
/// a move plays and schedules nothing, haptics included.
@MainActor final class SidebarGlidePlayer {
    private let sound: any SidebarSoundPlaying
    private let clock: any SidebarGlideClock
    private let haptic: @MainActor () -> Void
    private let reduceMotion: @MainActor () -> Bool
    /// The rows' centers, kept current by the sidebar as it lays out.
    var layout = SidebarLayout()
    /// The move in flight: where it began, when, and its destination's center.
    private var move: (start: SidebarGlide.Motion, began: TimeInterval, target: CGFloat)?
    private var pending: [any SidebarGlideTimer] = []

    /// - Parameters:
    ///   - haptic: Sent with each detent. The app's is a light alignment tap on a Force Touch trackpad, which macOS
    ///     ignores where there's none.
    init(sound: any SidebarSoundPlaying, clock: any SidebarGlideClock = DispatchGlideClock(),
         haptic: @escaping @MainActor () -> Void = SidebarGlidePlayer.trackpadTap,
         reduceMotion: @escaping @MainActor () -> Bool) {
        self.sound = sound
        self.clock = clock
        self.haptic = haptic
        self.reduceMotion = reduceMotion
    }

    /// How many detents are still to come. For tests.
    var pendingCount: Int { pending.count }

    /// Plays the sounds of the marker moving from `from` to `to`.
    func glide(from: Route, to: Route) {
        guard from != to else { return }
        cancelPending()
        let now = clock.now
        let target = layout.center(of: to)
        // Mid-glide, the new move starts where the marker is, still moving; otherwise from the row it rests on.
        let start = move.flatMap { SidebarGlide.motion(from: $0.start, to: $0.target, after: now - $0.began) }
            ?? SidebarGlide.Motion(position: layout.center(of: from))
        guard !reduceMotion() else {
            move = nil
            if sound.isAudible { sound.play(.glideShort) }
            return
        }
        move = (start, now, target)
        guard sound.isAudible else { return }
        let rows = SidebarGlide.order.filter { $0 != to }.map(layout.center(of:))
        let plan = SidebarGlide.plan(from: start, to: target, passing: rows)
        sound.play(plan.glide)
        for (index, delay) in plan.detents.enumerated() {
            pending.append(clock.schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.sound.play(.detent)
                self.haptic()
                if index == plan.detents.count - 1 { self.pending.removeAll() }
            })
        }
    }

    private func cancelPending() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }

    /// A light alignment tap on a Force Touch trackpad, felt while a finger rests on it.
    static func trackpadTap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
