import Foundation
import os

/// A stretch of sound sTools made itself, for its recordings: interleaved Float32 samples (`L R L R …` for two
/// channels) with their sample rate, channel count and host time.
public struct InProcessAudioBuffer: Equatable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var channelCount: Int
    /// When the first frame was rendered, in host time (`mach_absolute_time` ticks).
    public var hostTime: UInt64

    public init(samples: [Float], sampleRate: Double, channelCount: Int, hostTime: UInt64) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.hostTime = hostTime
    }

    public var frameCount: Int { channelCount > 0 ? samples.count / channelCount : 0 }
}

/// Sound sTools makes itself that its own recordings can carry on a track of its own, such as Timer Overlay's
/// alarm, the *Timer alarm* track (spec 5.4.1, 5.6.6). A process tap on sTools would also catch its UI sounds, so a
/// tool publishes into a named feed instead, and Screen Recording listens to every feed.
///
/// Feeds are made on first use and kept. A tool takes its feed at launch, so the feed is there before any recording
/// starts. A feed is only a name, a flag and its listeners: a silent one costs nothing.
public final class InProcessAudio: Sendable {
    /// The app's feeds.
    public static let shared = InProcessAudio()

    private let state = OSAllocatedUnfairLock<[InProcessAudioFeed]>(initialState: [])

    /// A set of feeds of its own; tests make one so nothing leaks between them.
    public init() {}

    /// The feed named `name`, made the first time it's asked for and the same one every time after.
    public func feed(named name: String) -> InProcessAudioFeed {
        state.withLock { feeds in
            if let feed = feeds.first(where: { $0.name == name }) { return feed }
            let feed = InProcessAudioFeed(name: name)
            feeds.append(feed)
            return feed
        }
    }

    /// Every feed made so far, oldest first.
    public var feeds: [InProcessAudioFeed] { state.withLock { $0 } }
}

/// One named source of sTools' own sound (`InProcessAudio`). Publishing is lock-protected and safe from an audio
/// thread; listeners run on the publisher's thread.
public final class InProcessAudioFeed: Sendable {
    public typealias Listener = @Sendable (InProcessAudioBuffer) -> Void

    /// Names a listener for `removeListener(_:)`.
    public struct ListenerToken: Hashable, Sendable {
        let id: Int
    }

    /// The feed's name, which is also its track's title in a recording.
    public let name: String

    private struct State {
        var wantsRecording = false
        var listeners: [Int: Listener] = [:]
        var nextID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(name: String) {
        self.name = name
    }

    /// Whether recordings carry this feed's track: a recording that starts while it's true does, for its whole
    /// length. The tool keeps it equal to its setting.
    public var wantsRecording: Bool {
        get { state.withLock { $0.wantsRecording } }
        set { state.withLock { $0.wantsRecording = newValue } }
    }

    /// Whether anything listens, such as an armed Screen Recording.
    public var hasListeners: Bool { state.withLock { !$0.listeners.isEmpty } }

    /// Sends every buffer published from now on to `listener`, until it's removed.
    public func addListener(_ listener: @escaping Listener) -> ListenerToken {
        state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.listeners[id] = listener
            return ListenerToken(id: id)
        }
    }

    public func removeListener(_ token: ListenerToken) {
        _ = state.withLock { $0.listeners.removeValue(forKey: token.id) }
    }

    /// Hands `buffer` to every listener on the calling thread. Without listeners it does nothing.
    public func publish(_ buffer: InProcessAudioBuffer) {
        let listeners = state.withLock { state in state.listeners.isEmpty ? [] : Array(state.listeners.values) }
        for listener in listeners { listener(buffer) }
    }
}
