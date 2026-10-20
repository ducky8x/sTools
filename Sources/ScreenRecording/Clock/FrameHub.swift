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

    private let state = OSAllocatedUnfairLock(initialState: [SourceKey: Slot]())

    public init() {}

    /// Stores `frame` as the latest of `key`, replacing an earlier frame no tick has used yet.
    public func submit(_ frame: VideoFrame, for key: SourceKey) {
        state.withLock { slots in
            var slot = slots[key] ?? Slot()
            slot.stats.received += 1
            if slot.frame != nil, !slot.consumed { slot.stats.coalesced += 1 }
            slot.frame = frame
            slot.consumed = false
            slots[key] = slot
        }
    }

    /// Empties a slot (its window closed). The compositor skips the source from the next tick on.
    public func clear(_ key: SourceKey) {
        state.withLock { slots in
            guard var slot = slots[key] else { return }
            slot.frame = nil
            slot.consumed = true
            slots[key] = slot
        }
    }

    /// Hides a slot without forgetting its last frame (a minimized window with "show nothing").
    public func setHidden(_ hidden: Bool, for key: SourceKey) {
        state.withLock { slots in
            var slot = slots[key] ?? Slot()
            slot.hidden = hidden
            slots[key] = slot
        }
    }

    /// The latest frame of every visible source. Call once per tick.
    public func snapshot() -> FrameSnapshot {
        state.withLock { slots in
            var frames: [SourceKey: SnapshotFrame] = [:]
            for key in Array(slots.keys) {
                guard var slot = slots[key], let frame = slot.frame, !slot.hidden else { continue }
                let isNew = !slot.consumed
                if !isNew { slot.stats.reused += 1 }
                slot.consumed = true
                slots[key] = slot
                frames[key] = SnapshotFrame(frame: frame, isNew: isNew)
            }
            return FrameSnapshot(frames: frames)
        }
    }

    /// The latest frame of every visible source, without marking anything used: for the live preview, which
    /// must not disturb the recording's accounting.
    public func peek() -> [SourceKey: VideoFrame] {
        state.withLock { slots in
            slots.compactMapValues { slot in slot.hidden ? nil : slot.frame }
        }
    }

    public func stats(for key: SourceKey) -> HubStats {
        state.withLock { $0[key]?.stats ?? HubStats() }
    }

    /// Drops every stored frame, releasing their buffers.
    public func removeAll() {
        state.withLock { $0.removeAll() }
    }
}
