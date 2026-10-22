import CoreMedia
import CoreVideo
import Foundation
import os

/// Names a slot in the compositor: the fixed base layer or one of the layout's video sources.
public enum SourceKey: Hashable, Sendable {
    case base
    case source(UUID)
}

/// One captured video frame.
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// The part of the buffer that holds content, in pixels with a top-left origin.
    /// ScreenCaptureKit window captures fill only part of the buffer when the window is resized; nil means all of it.
    public let contentRect: PixelRect?
    /// When the frame was captured, on the host clock.
    public let hostTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, contentRect: PixelRect? = nil, hostTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.contentRect = contentRect
        self.hostTime = hostTime
    }

    public var pixelSize: PixelSize {
        PixelSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }

    /// The size of the content, honoring `contentRect`.
    public var contentSize: PixelSize {
        guard let rect = contentRect else { return pixelSize }
        return PixelSize(width: max(1, Int(rect.width.rounded())), height: max(1, Int(rect.height.rounded())))
    }
}

/// A frame as the compositor sees it on one tick.
public struct SnapshotFrame: Sendable {
    public let frame: VideoFrame
    /// False when this exact frame was already used by an earlier tick (the source was idle).
    public let isNew: Bool
}

public struct FrameSnapshot: Sendable {
    public var frames: [SourceKey: SnapshotFrame]
}

public struct HubStats: Equatable, Sendable {
    /// Frames delivered by the source.
    public var received = 0
    /// Frames replaced by a newer one before any tick used them.
    public var coalesced = 0
    /// Ticks that reused a frame they had already composited.
    public var reused = 0
}

/// Holds the latest frame of every source. Sources deliver only when their content changes, and in bursts;
/// the frame clock composites whatever is latest on each tick.
public final class FrameHub: @unchecked Sendable {
    private struct Slot {
        var frame: VideoFrame?
        var consumed = true
        var hidden = false
        var stats = HubStats()
    }

    /// Someone waiting for a slot's first frame (`waitForFrame`).
    private struct Waiter {
        let key: SourceKey
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var slots: [SourceKey: Slot] = [:]
        var waiters: [UInt64: Waiter] = [:]
        var nextWaiter: UInt64 = 0

        /// Takes the waiters for `key`, or for every slot when nil.
        mutating func takeWaiters(for key: SourceKey?) -> [Waiter] {
            let taken = waiters.filter { key == nil || $0.value.key == key }
            for id in taken.keys { waiters[id] = nil }
            return Array(taken.values)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Stores `frame` as the latest of `key`, replacing an earlier frame no tick has used yet.
    public func submit(_ frame: VideoFrame, for key: SourceKey) {
        let waiters = state.withLock { state in
            var slot = state.slots[key] ?? Slot()
            slot.stats.received += 1
            if slot.frame != nil, !slot.consumed { slot.stats.coalesced += 1 }
            slot.frame = frame
            slot.consumed = false
            state.slots[key] = slot
            return state.takeWaiters(for: key)
        }
        for waiter in waiters { waiter.continuation.resume(returning: true) }
    }

    /// Empties a slot (its window closed). The compositor skips the source from the next tick on, and a wait for its
    /// first frame ends.
    public func clear(_ key: SourceKey) {
        let waiters = state.withLock { state in
            if var slot = state.slots[key] {
                slot.frame = nil
                slot.consumed = true
                state.slots[key] = slot
            }
            return state.takeWaiters(for: key)
        }
        for waiter in waiters { waiter.continuation.resume(returning: false) }
    }

    /// Hides a slot without forgetting its last frame (a minimized window with "show nothing").
    public func setHidden(_ hidden: Bool, for key: SourceKey) {
        state.withLock { state in
            var slot = state.slots[key] ?? Slot()
            slot.hidden = hidden
            state.slots[key] = slot
        }
    }

    /// Waits until `key` has a frame, for `timeout` at most: a recording's start waits for Minecraft's first frame,
    /// so its file doesn't open on a black canvas (spec 5.4.4). True once there is one; false when the wait timed
    /// out, or the slot or every frame was let go of.
    public func waitForFrame(of key: SourceKey, timeout: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let id: UInt64? = state.withLock { state in
                guard state.slots[key]?.frame == nil else { return nil }
                let id = state.nextWaiter
                state.nextWaiter += 1
                state.waiters[id] = Waiter(key: key, continuation: continuation)
                return id
            }
            guard let id else {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.endWait(id)
            }
        }
    }

    private func endWait(_ id: UInt64) {
        let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
        waiter?.continuation.resume(returning: false)
    }

    /// The latest frame of every visible source. Call once per tick.
    public func snapshot() -> FrameSnapshot {
        state.withLock { state in
            var frames: [SourceKey: SnapshotFrame] = [:]
            for key in Array(state.slots.keys) {
                guard var slot = state.slots[key], let frame = slot.frame, !slot.hidden else { continue }
                let isNew = !slot.consumed
                if !isNew { slot.stats.reused += 1 }
                slot.consumed = true
                state.slots[key] = slot
                frames[key] = SnapshotFrame(frame: frame, isNew: isNew)
            }
            return FrameSnapshot(frames: frames)
        }
    }

    /// The latest frame of every visible source, without marking anything used: for the live preview, which
    /// must not disturb the recording's accounting.
    public func peek() -> [SourceKey: VideoFrame] {
        state.withLock { state in
            state.slots.compactMapValues { slot in slot.hidden ? nil : slot.frame }
        }
    }

    public func stats(for key: SourceKey) -> HubStats {
        state.withLock { $0.slots[key]?.stats ?? HubStats() }
    }

    /// Drops every stored frame, releasing their buffers, and ends every wait for a first frame.
    public func removeAll() {
        let waiters = state.withLock { state in
            state.slots.removeAll()
            return state.takeWaiters(for: nil)
        }
        for waiter in waiters { waiter.continuation.resume(returning: false) }
    }
}
