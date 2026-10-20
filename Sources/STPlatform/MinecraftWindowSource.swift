import Foundation

/// Where the locator learns about Minecraft windows. The real source reads the Accessibility API;
/// tests and previews use `StaticMinecraftWindowSource`.
@MainActor
public protocol MinecraftWindowSource: AnyObject {
    /// Every Minecraft game window that exists right now.
    func snapshot() -> [MinecraftInstance]

    /// Yields whenever something relevant may have changed. Event driven: no polling.
    /// Implementations should buffer at most one pending value so bursts collapse.
    func changes() -> AsyncStream<Void>
}

/// A source whose windows are set by hand. Used by tests and by SwiftUI previews.
@MainActor
public final class StaticMinecraftWindowSource: MinecraftWindowSource {
    public var instances: [MinecraftInstance] {
        didSet { if instances != oldValue { _ = continuation?.yield() } }
    }
    private var continuation: AsyncStream<Void>.Continuation?
    private var stream: AsyncStream<Void>?

    public init(instances: [MinecraftInstance] = []) {
        self.instances = instances
    }

    public func snapshot() -> [MinecraftInstance] { instances }

    public func changes() -> AsyncStream<Void> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    /// Forces a change event even when `instances` is unchanged.
    public func poke() { _ = continuation?.yield() }
}
