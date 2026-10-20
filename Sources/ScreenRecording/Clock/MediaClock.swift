import CoreMedia
import Foundation

/// The clock every video tick and audio sample is stamped with. In production it is the host clock,
/// which ScreenCaptureKit, AVFoundation and Core Audio all use, so video and audio share one timeline.
public protocol MediaClock: Sendable {
    func now() -> CMTime
}

public struct HostMediaClock: MediaClock {
    public init() {}

    public func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}

extension CMTime {
    /// A time in seconds as a `CMTime` with nanosecond resolution.
    static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 1_000_000_000)
    }
}
