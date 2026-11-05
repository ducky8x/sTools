import Darwin
import Dispatch
import Foundation

/// Reads whether macOS shows the pointer now, for the whole screen, not only for sTools. Minecraft hides the pointer while
/// it holds it in the game and shows it in its menus, inventories and pause screen, and it posts nothing either way, so
/// this is how sTools tells the two apart while Minecraft is in front.
public protocol PointerVisibilityReading: Sendable {
    /// Whether this macOS has the call.
    var isSupported: Bool { get }
    /// Whether the pointer shows now; nil without the call. Safe off the main actor.
    func isPointerVisible() -> Bool?
}

/// Reads `CGCursorIsVisible()`, which reports the pointer for every app (checked on macOS 27.2: it flips as another app
/// hides and shows its pointer). It's deprecated, so it's looked up by name when sTools starts rather than linked: a macOS
/// without it still opens sTools, and the Crosshair then can't hide in Minecraft's menus. It only reads; it changes nothing.
/// One call costs about 0.03 µs: it reads memory the window server shares, without a round trip.
public struct LivePointerVisibility: PointerVisibilityReading {
    private typealias IsVisible = @convention(c) () -> Int32

    private let call: IsVisible?

    public init() {
        let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        call = dlsym(library, "CGCursorIsVisible").map { unsafeBitCast($0, to: IsVisible.self) }
    }

    public var isSupported: Bool { call != nil }

    public func isPointerVisible() -> Bool? {
        call.map { $0() != 0 }
    }
}

/// Watches whether the pointer shows and reports each change on the main actor.
@MainActor
public protocol PointerVisibilityWatching: AnyObject {
    /// Whether the pointer can be watched on this macOS.
    var isSupported: Bool { get }
    /// Whether it's watching now.
    var isWatching: Bool { get }
    /// Starts watching. `onChange` gets the pointer's state before this returns, then every change until `stop()`.
    func start(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void)
    func stop()
}

/// Reads the pointer's state every `interval` (50 ms) on a queue of its own, and hops to the main actor only when it
/// changes. A tick is one call and a comparison, with nothing allocated. It runs only between `start()` and `stop()`:
/// the Crosshair starts it only while one of its menu settings is on, it's on, and Minecraft is in front.
@MainActor
public final class PointerVisibilityPoller: PointerVisibilityWatching {
    public static let interval: Duration = .milliseconds(50)

    /// The last state a tick read, touched only on the poller's queue (and once by `start` before the timer runs).
    private final class LastReading: @unchecked Sendable {
        var visible: Bool?
    }

    private let reader: any PointerVisibilityReading
    private let interval: Duration
    private let queue = DispatchQueue(label: "com.ducky8x.sTools.pointer-visibility", qos: .userInteractive)
    private var timer: (any DispatchSourceTimer)?
    /// Goes up with every start and stop, so a change a tick sent before a stop is dropped when it arrives.
    private var generation = 0

    public init(reader: any PointerVisibilityReading = LivePointerVisibility(), interval: Duration = PointerVisibilityPoller.interval) {
        self.reader = reader
        self.interval = interval
    }

    public var isSupported: Bool { reader.isSupported }
    public var isWatching: Bool { timer != nil }

    public func start(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        stop()
        guard isSupported else { return }
        generation += 1
        let generation = generation
        let reader = reader
        let last = LastReading()
        // The first reading comes at once, so the Crosshair never shows over a menu while it waits for a tick.
        last.visible = reader.isPointerVisible()
        let deliver: @MainActor @Sendable (Bool) -> Void = { [weak self] visible in
            guard let self, self.generation == generation else { return }
            onChange(visible)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let nanoseconds = Int(interval.components.seconds * 1_000_000_000 + interval.components.attoseconds / 1_000_000_000)
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .nanoseconds(nanoseconds),
                       leeway: .nanoseconds(nanoseconds / 10))
        timer.setEventHandler(handler: Self.tick(reader: reader, last: last, deliver: deliver))
        self.timer = timer
        timer.resume()
        if let visible = last.visible { onChange(visible) }
    }

    /// One tick, made outside the main actor so it runs on the poller's queue: a closure made in `start` would belong to
    /// the main actor, and Swift stops the app when such a closure runs anywhere else.
    private nonisolated static func tick(reader: any PointerVisibilityReading, last: LastReading,
                                         deliver: @escaping @MainActor @Sendable (Bool) -> Void) -> @Sendable () -> Void {
        {
            guard let visible = reader.isPointerVisible(), visible != last.visible else { return }
            last.visible = visible
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(visible) } }
        }
    }

    public func stop() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        generation += 1
    }
}
