import CoreMedia
import CoreVideo
import Foundation
import os
@testable import ScreenRecording

/// A clock the test moves by hand.
final class ManualClock: MediaClock, @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0.0)

    init(_ seconds: Double = 0) { value.withLock { $0 = seconds } }

    func now() -> CMTime { .seconds(value.withLock { $0 }) }
    func set(_ seconds: Double) { value.withLock { $0 = seconds } }
    func advance(by seconds: Double) { value.withLock { $0 += seconds } }
}

/// A tick driver the test fires by hand.
final class ManualTickDriver: TickDriver, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable () -> Void)?
        var intervals: [Double] = []
        var stops = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(interval: Double, handler: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.intervals.append(interval)
            $0.handler = handler
        }
    }

    func stop() {
        state.withLock {
            $0.handler = nil
            $0.stops += 1
        }
    }

    var isRunning: Bool { state.withLock { $0.handler != nil } }
    var intervals: [Double] { state.withLock { $0.intervals } }
    var stopCount: Int { state.withLock { $0.stops } }

    /// Wakes the clock once, as a timer would. Does nothing when stopped.
    func fire() {
        let handler = state.withLock { $0.handler }
        handler?()
    }
}

final class TickRecorder: @unchecked Sendable {
    private let ticks = OSAllocatedUnfairLock(initialState: [FrameTick]())
    func record(_ tick: FrameTick) { ticks.withLock { $0.append(tick) } }
    var all: [FrameTick] { ticks.withLock { $0 } }
}

enum ClockTestFrames {
    /// A small BGRA frame; tests tell frames apart by `hostTime`.
    static func frame(at seconds: Double) -> VideoFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed")
        return VideoFrame(pixelBuffer: buffer!, hostTime: .seconds(seconds))
    }
}
