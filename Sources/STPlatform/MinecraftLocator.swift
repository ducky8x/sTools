import Foundation
import Observation

/// Publishes which Minecraft instance the tools follow (rule R11) and whether there is a conflict.
@MainActor @Observable
public final class MinecraftLocator {
    public private(set) var instances: [MinecraftInstance] = []
    public private(set) var active: MinecraftInstance?
    public private(set) var conflict: InstanceConflict = .none

    @ObservationIgnored private let source: any MinecraftWindowSource
    @ObservationIgnored private let preferredVersion: String
    @ObservationIgnored private let coalescing: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(source: any MinecraftWindowSource, preferredVersion: String = "1.16.1", coalescing: Duration = .milliseconds(30)) {
        self.source = source
        self.preferredVersion = preferredVersion
        self.coalescing = coalescing
    }

    public var isRunning: Bool { task != nil }

    /// The loop that follows the source's changes while running; it ends once the source's changes end. Tests await
    /// it to know every change so far has been handled, instead of sleeping for a fixed time.
    var changeLoop: Task<Void, Never>? { task }

    /// Takes a snapshot now, then again after every source change. Calling it twice is harmless.
    public func start() {
        guard task == nil else { return }
        refresh()
        let stream = source.changes()
        task = Task { @MainActor [weak self, coalescing] in
            for await _ in stream {
                try? await Task.sleep(for: coalescing)
                if Task.isCancelled { return }
                self?.refresh()
            }
        }
    }

    /// Stops all background work. The last published values stay readable.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Re-reads the source immediately (for example right after Accessibility is granted).
    public func refresh() {
        let all = source.snapshot()
        let selection = InstanceSelector.select(from: all, preferredVersion: preferredVersion)
        if selection.all != instances { instances = selection.all }
        if selection.active != active { active = selection.active }
        if selection.conflict != conflict { conflict = selection.conflict }
    }
}
