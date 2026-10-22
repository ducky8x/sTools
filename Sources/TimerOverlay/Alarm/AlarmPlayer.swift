import AVFoundation
import Foundation
import STDesign
import STPlatform

// MARK: - What the controller and the recording bridge use

/// A stretch of the alarm's output as it was rendered, for sTools' recordings (the *Timer alarm* track):
/// interleaved Float32 samples with their sample rate, channel count and host time.
public struct AlarmRenderedBuffer: Equatable, Sendable {
    /// Interleaved samples: `L R L R …` for two channels.
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

/// Plays Timer Overlay's alarm, its cues before zero and the page's preview (spec 5.6.6), each at the alarm's own
/// volume: sTools' Sounds setting and macOS's interface sounds don't apply, while the Mac's own volume and mute do.
///
/// One thing plays at a time: starting one stops whatever played before, as `stop()` does, and the stopped one's
/// callbacks never run. The live one is `AlarmPlayer`.
@MainActor
public protocol AlarmPlaying: AnyObject {
    /// Whether an alarm, a cue or a preview is playing.
    var isPlaying: Bool { get }

    /// Receives the output as it's rendered, on the audio tap's thread, for sTools' recordings. The tap exists
    /// only while this is set and something plays.
    var onRenderedBuffer: (@Sendable (AlarmRenderedBuffer) -> Void)? { get set }

    /// Rings `sound` at `volume` (0...1) at `schedule`'s times, counted from now: once at each of its ring starts,
    /// never past `alarmEnd`. `onRing(index)` runs as each ring starts, the first included, and `onEnd()` once
    /// the last sound has been heard.
    func ring(_ sound: URL, volume: Double, schedule: AlarmSchedule,
              onRing: @escaping @MainActor (_ index: Int) -> Void, onEnd: @escaping @MainActor () -> Void)

    /// Plays a cue before zero once, at the alarm's `volume`: sTools' chime or a tick.
    func playCue(_ cue: AlarmSchedule.Cue, volume: Double)

    /// Plays `sound` the way the alarm would, `rings` times 0.35 s apart, for the page. `onEnd()` runs once it
    /// has been heard.
    func preview(_ sound: URL, volume: Double, rings: Int, onEnd: @escaping @MainActor () -> Void)

    /// Stops whatever plays, at once, and lets its audio engine go. No callback of it runs after this.
    func stop()
}

// MARK: - The plan

/// One piece of a playback, played back to back on the player node. Frames count at the sound's own sample rate.
public enum AlarmPlaybackItem: Equatable, Sendable {
    case silence(frames: Int)
    /// The sound's frames `start ..< start + count`.
    case sound(start: Int, count: Int)
    /// The same, fading out to silence along its length: where a ring is cut short, so the cut never clicks.
    case fadeOut(start: Int, count: Int)

    public var frameCount: Int {
        switch self {
        case .silence(let frames): frames
        case .sound(_, let count), .fadeOut(_, let count): count
        }
    }
}

/// What one playback schedules on the player node, and when it reports: each ring starts as the item before it has
/// been heard, and the playback ends as its last item has. Pure: nothing here plays or waits.
public struct AlarmPlaybackPlan: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case ring(Int)
        case end
    }

    /// An event, the item whose end marks it, and when that is, in seconds from the start of playback.
    public struct Mark: Equatable, Sendable {
        public let event: Event
        public let afterItem: Int
        public let time: TimeInterval
    }

    /// Silence before the first ring, so that ring's start is reported like every other's: when the item before it
    /// has been heard.
    public static let leadIn: TimeInterval = 0.01
    /// The fade where a ring is cut short.
    public static let fadeLength: TimeInterval = 0.02
    /// The longest silence item; a longer gap is several, so no silence needs a big buffer.
    public static let longestSilence: TimeInterval = 1

    public let items: [AlarmPlaybackItem]
    /// In order; the last is `.end`.
    public let marks: [Mark]

    /// Rings a sound `soundFrames` long, at `sampleRate`, at `schedule`'s times: once at each ring start, each ring
    /// stopping at the sound's end, the next ring's start or `alarmEnd`, whichever comes first.
    public init(schedule: AlarmSchedule, soundFrames: Int, sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let frames = max(0, soundFrames)
        let lead = max(1, Int((Self.leadIn * rate).rounded()))
        let fade = max(1, Int((Self.fadeLength * rate).rounded()))
        let longestSilence = max(1, Int((Self.longestSilence * rate).rounded()))
        func position(_ time: TimeInterval) -> Int { lead + Int((max(0, time) * rate).rounded()) }

        var items: [AlarmPlaybackItem] = []
        var marks: [Mark] = []
        var cursor = 0
        func appendSilence(until end: Int) {
            while cursor < end {
                let count = min(end - cursor, longestSilence)
                items.append(.silence(frames: count))
                cursor += count
            }
        }

        appendSilence(until: lead)
        let alarmEnd = position(schedule.alarmEnd)
        let starts = schedule.ringStarts.map(position)
        for (index, scheduled) in starts.enumerated() {
            let start = max(scheduled, cursor)
            let next = index + 1 < starts.count ? starts[index + 1] : Int.max
            let count = min(frames, alarmEnd - start, next - start)
            guard count > 0 else { break }
            appendSilence(until: start)
            marks.append(Mark(event: .ring(index), afterItem: items.count - 1, time: Double(start) / rate))
            if count < frames {
                let fadeCount = min(fade, count)
                if count > fadeCount { items.append(.sound(start: 0, count: count - fadeCount)) }
                items.append(.fadeOut(start: count - fadeCount, count: fadeCount))
            } else {
                items.append(.sound(start: 0, count: count))
            }
            cursor = start + count
        }
        marks.append(Mark(event: .end, afterItem: items.count - 1, time: Double(cursor) / rate))
        self.items = items
        self.marks = marks
    }

    /// How long the playback lasts, in seconds.
    public var duration: TimeInterval { marks.last?.time ?? 0 }
}

// MARK: - The audio engine behind it

/// One playback's audio engine: one sound file through a player node into the main mixer. The player builds one
/// per alarm, cue or preview and lets it go after, so nothing audio exists while nothing plays. The live one is
/// `AVAudioEngine`; tests use a fake that plays nothing.
@MainActor
public protocol AlarmAudioEngine: AnyObject {
    /// The sound's length in frames.
    var soundFrameCount: Int { get }
    /// The sound's sample rate.
    var sampleRate: Double { get }
    /// Called on the main actor if the system stops the engine, after an output change for example.
    var onInterruption: (@MainActor () -> Void)? { get set }

    /// Schedules `items` back to back on the node, then starts the engine and the node at `volume`. Calls
    /// `onItemPlayed(index)` on the main actor once item `index` has been heard. Stopping may also call it, early,
    /// for items it cut short.
    func play(_ items: [AlarmPlaybackItem], volume: Float, onItemPlayed: @escaping @MainActor (Int) -> Void) throws

    /// Sends what the engine renders to `handler`, on the tap's own thread, until `removeTap()`.
    func installTap(_ handler: @escaping @Sendable (AlarmRenderedBuffer) -> Void)
    func removeTap()

    /// Stops the node and the engine at once.
    func stop()
}

/// Opens a sound and builds an engine to play it, without starting anything.
@MainActor
public protocol AlarmEngineMaking {
    func makeEngine(for sound: URL) throws -> any AlarmAudioEngine
}

// MARK: - The live player

/// The alarm player (spec 5.6.6, 5.6.10).
///
/// - Cost: nothing exists until something plays, and nothing is loaded ahead of time. Each alarm, cue or preview
///   builds its own engine and lets it go as its last sound has been heard, or at once on `stop()`. If the engine
///   never says so, the player's clock lets it go `lateness` after the sound's planned end.
/// - Timing: the rings are scheduled on the engine's player node, to the sample, not by timers. Each ring's start
///   is reported as the engine reaches it. The clock reports any the engine doesn't, `lateness` late; with no engine
///   at all (the sound can't be opened, the engine can't start, or the system stopped it) it reports them on time,
///   so the overlay's pulses go on even when the sound can't.
/// - The tap for sTools' recordings exists only while `onRenderedBuffer` is set and something plays.
@MainActor
public final class AlarmPlayer: AlarmPlaying {
    /// How long after its planned time the clock reports what the engine hasn't, and so how long an engine can
    /// outlive its last sound.
    public static let lateness: TimeInterval = 0.5
    /// How early the engine may report an item. Earlier means the node was stopped, not that the item was heard.
    static let earliness: TimeInterval = 0.1
    /// The sample rate the plan assumes when no engine could open the sound.
    private static let assumedRate = 48_000.0
    /// The length a cue or preview assumes when no engine could open the sound: Ping's.
    private static let assumedLength: TimeInterval = 1.5

    public var isPlaying: Bool { playback != nil }
    /// Whether an audio engine exists right now.
    public var hasEngine: Bool { playback?.engine != nil }

    public var onRenderedBuffer: (@Sendable (AlarmRenderedBuffer) -> Void)? {
        didSet { updateTap() }
    }

    private let engines: any AlarmEngineMaking
    private let clock: any TimerClock
    private let scheduler: any TimerScheduling
    private let log = STLog.logger("AlarmPlayer")
    private var playback: Playback?
    private var lastID = 0

    public init(engines: any AlarmEngineMaking = LiveAlarmEngines(), clock: any TimerClock = MonotonicClock(),
                scheduler: any TimerScheduling = DispatchTimerScheduler()) {
        self.engines = engines
        self.clock = clock
        self.scheduler = scheduler
    }

    // MARK: Playing

    public func ring(_ sound: URL, volume: Double, schedule: AlarmSchedule,
                     onRing: @escaping @MainActor (_ index: Int) -> Void, onEnd: @escaping @MainActor () -> Void) {
        begin(sound, volume: volume, onRing: onRing, onEnd: onEnd) { _ in schedule }
    }

    public func playCue(_ cue: AlarmSchedule.Cue, volume: Double) {
        let sound: STSound = switch cue {
        case .chime: .chime
        case .tick: .tick
        }
        guard let url = sound.resourceURL else {
            log.error("Missing cue sound \(sound.rawValue, privacy: .public).wav")
            stop()
            return
        }
        begin(url, volume: volume, onRing: nil, onEnd: nil) { Self.plainSchedule(soundLength: $0, rings: 1) }
    }

    public func preview(_ sound: URL, volume: Double, rings: Int, onEnd: @escaping @MainActor () -> Void) {
        let rings = min(max(rings, TimerOverlaySettings.ringsRange.lowerBound), TimerOverlaySettings.ringsRange.upperBound)
        begin(sound, volume: volume, onRing: nil, onEnd: onEnd) { Self.plainSchedule(soundLength: $0, rings: rings) }
    }

    public func stop() {
        guard let stopped = playback else { return }
        playback = nil
        stopped.wake?.cancel()
        stopped.wake = nil
        letEngineGo(stopped)
    }

    /// Plays `sound`: builds its engine and plan, starts it, and keeps the next report's wake pending.
    /// - Parameter schedule: the schedule, given the sound's length in seconds.
    private func begin(
        _ sound: URL, volume: Double, onRing: (@MainActor (Int) -> Void)?, onEnd: (@MainActor () -> Void)?,
        schedule: (TimeInterval) -> AlarmSchedule
    ) {
        stop()
        let engine = openEngine(for: sound)
        let plan: AlarmPlaybackPlan
        if let engine {
            plan = AlarmPlaybackPlan(
                schedule: schedule(Double(engine.soundFrameCount) / engine.sampleRate),
                soundFrames: engine.soundFrameCount, sampleRate: engine.sampleRate)
        } else {
            let assumed = schedule(Self.assumedLength)
            plan = AlarmPlaybackPlan(
                schedule: assumed, soundFrames: Int((assumed.soundLength * Self.assumedRate).rounded()),
                sampleRate: Self.assumedRate)
        }
        lastID += 1
        let id = lastID
        let playback = Playback(id: id, plan: plan, engine: engine, onRing: onRing, onEnd: onEnd)
        self.playback = playback
        playback.start = clock.now()
        if let engine {
            engine.onInterruption = { [weak self] in self?.engineStopped(id) }
            if let onRenderedBuffer {
                engine.installTap(onRenderedBuffer)
                playback.isTapped = true
            }
            do {
                try engine.play(plan.items, volume: Self.clamped(volume)) { [weak self] item in
                    self?.itemPlayed(item, of: id)
                }
            } catch {
                log.error("The alarm's audio engine didn't start: \(error.localizedDescription, privacy: .public)")
                letEngineGo(playback)
            }
        }
        scheduleNextReport()
    }

    /// An engine for `sound`, or for Ping when `sound` can't be opened, or nil when neither can.
    private func openEngine(for sound: URL) -> (any AlarmAudioEngine)? {
        do {
            return try engines.makeEngine(for: sound)
        } catch {
            log.error("Couldn't open an alarm sound; Ping plays instead: \(error.localizedDescription, privacy: .public)")
        }
        let fallback = AlarmSound.fallback().url
        guard fallback.standardizedFileURL != sound.standardizedFileURL else { return nil }
        do {
            return try engines.makeEngine(for: fallback)
        } catch {
            log.error("Couldn't open Ping either; the alarm is silent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Reporting

    /// The engine has played `item` out: report the marks it reached, unless it came well before their time, which
    /// means the node was stopped rather than heard.
    private func itemPlayed(_ item: Int, of id: Int) {
        guard let playback, playback.id == id, playback.engine != nil else { return }
        let elapsed = clock.now() - playback.start
        guard let last = playback.plan.marks.lastIndex(where: { $0.afterItem <= item && $0.time <= elapsed + Self.earliness }),
              last >= playback.reported
        else { return }
        report(through: last)
    }

    /// Reports the plan's marks up to `last`, in order. A ring's or the end's callback may start or stop something,
    /// so each step checks the playback is still the same one.
    private func report(through last: Int) {
        guard let id = playback?.id else { return }
        while let current = playback, current.id == id, current.reported <= last,
              current.reported < current.plan.marks.count {
            let mark = current.plan.marks[current.reported]
            current.reported += 1
            switch mark.event {
            case .ring(let index):
                current.onRing?(index)
            case .end:
                finish()
                return
            }
        }
        if playback?.id == id { scheduleNextReport() }
    }

    /// Keeps one wake pending, for the next mark: `lateness` after its time while an engine plays, on time without one.
    private func scheduleNextReport() {
        guard let playback else { return }
        playback.wake?.cancel()
        playback.wake = nil
        guard playback.reported < playback.plan.marks.count else { return }
        let index = playback.reported
        let allowance = playback.engine == nil ? 0 : Self.lateness
        let delay = playback.start + playback.plan.marks[index].time + allowance - clock.now()
        let id = playback.id
        playback.wake = scheduler.schedule(after: max(0, delay)) { [weak self] in
            guard let self, let playback = self.playback, playback.id == id else { return }
            playback.wake = nil
            self.report(through: index)
        }
    }

    /// The system stopped the engine: let it go, and let the clock report the rest on time.
    private func engineStopped(_ id: Int) {
        guard let playback, playback.id == id, playback.engine != nil else { return }
        log.notice("The system stopped the alarm's audio engine; the rest of the alarm follows the clock")
        letEngineGo(playback)
        scheduleNextReport()
    }

    private func finish() {
        guard let ended = playback else { return }
        playback = nil
        ended.wake?.cancel()
        ended.wake = nil
        letEngineGo(ended)
        ended.onEnd?()
    }

    // MARK: The engine and its tap

    private func letEngineGo(_ playback: Playback) {
        guard let engine = playback.engine else { return }
        // First, so whatever the engine reports while it stops counts for nothing.
        playback.engine = nil
        if playback.isTapped {
            engine.removeTap()
            playback.isTapped = false
        }
        engine.onInterruption = nil
        engine.stop()
    }

    private func updateTap() {
        guard let playback, let engine = playback.engine else { return }
        if playback.isTapped {
            engine.removeTap()
            playback.isTapped = false
        }
        if let onRenderedBuffer {
            engine.installTap(onRenderedBuffer)
            playback.isTapped = true
        }
    }

    // MARK: Values

    /// The volume within 0...1; NaN is silent.
    static func clamped(_ volume: Double) -> Float {
        guard volume.isFinite else { return volume > 0 ? 1 : 0 }
        return Float(min(max(volume, 0), 1))
    }

    /// `rings` plays of a sound `soundLength` long, the usual gap apart, ending with the last: a cue or a preview
    /// (the explicit schedule with "after the last ring", as the alarm itself uses).
    private static func plainSchedule(soundLength: TimeInterval, rings: Int) -> AlarmSchedule {
        AlarmSchedule(soundLength: soundLength, rings: rings, leave: .afterLastRing, leaveAfterLastRing: 0,
                      leaveAfterZero: 0, whileRinging: .timesUpLookOnly)
    }

    /// One alarm, cue or preview while it plays.
    @MainActor
    private final class Playback {
        let id: Int
        let plan: AlarmPlaybackPlan
        var engine: (any AlarmAudioEngine)?
        var isTapped = false
        /// When it started, on the clock.
        var start: TimeInterval = 0
        /// How many of the plan's marks have been reported.
        var reported = 0
        var wake: (any TimerScheduledWake)?
        let onRing: (@MainActor (Int) -> Void)?
        let onEnd: (@MainActor () -> Void)?

        init(id: Int, plan: AlarmPlaybackPlan, engine: (any AlarmAudioEngine)?,
             onRing: (@MainActor (Int) -> Void)?, onEnd: (@MainActor () -> Void)?) {
            self.id = id
            self.plan = plan
            self.engine = engine
            self.onRing = onRing
            self.onEnd = onEnd
        }
    }
}

// MARK: - The live engine

/// Builds a `LiveAlarmEngine` for each playback.
public struct LiveAlarmEngines: AlarmEngineMaking {
    public init() {}

    public func makeEngine(for sound: URL) throws -> any AlarmAudioEngine {
        try LiveAlarmEngine(sound: sound)
    }
}

/// `AVAudioEngine` playing one sound file through an `AVAudioPlayerNode` into its main mixer.
///
/// Opening it only reads the file: the engine and its output are made when it plays, and go when it stops. It uses
/// the engine's output only, never its input, which would ask for the microphone.
@MainActor
final class LiveAlarmEngine: AlarmAudioEngine {
    enum Failure: Error {
        case empty
        case noBuffer
    }

    let soundFrameCount: Int
    let sampleRate: Double
    var onInterruption: (@MainActor () -> Void)?

    private let file: AVAudioFile
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var tapHandler: (@Sendable (AlarmRenderedBuffer) -> Void)?
    private var isTapped = false

    init(sound: URL) throws {
        let file = try AVAudioFile(forReading: sound)
        guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw Failure.empty }
        self.file = file
        soundFrameCount = Int(file.length)
        sampleRate = file.processingFormat.sampleRate
    }

    /// Whether the audio engine exists: only from `play` to `stop`.
    var hasAudioEngine: Bool { engine != nil }

    func play(_ items: [AlarmPlaybackItem], volume: Float, onItemPlayed: @escaping @MainActor (Int) -> Void) throws {
        let format = file.processingFormat
        // Every buffer is made before anything is scheduled, so reading the file for a fade never overlaps the
        // node's own reads.
        var buffers: [Int: AVAudioPCMBuffer] = [:]
        var silences: [Int: AVAudioPCMBuffer] = [:]
        for (index, item) in items.enumerated() {
            switch item {
            case .sound:
                continue
            case .silence(let frames):
                let silence = try silences[frames] ?? Self.silentBuffer(format: format, frames: frames)
                silences[frames] = silence
                buffers[index] = silence
            case .fadeOut(let start, let count):
                buffers[index] = try Self.fadedBuffer(from: file, start: start, count: count)
            }
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = volume
        for (index, item) in items.enumerated() {
            let played = Self.completion { onItemPlayed(index) }
            switch item {
            case .sound(let start, let count):
                node.scheduleSegment(
                    file, startingFrame: AVAudioFramePosition(start), frameCount: AVAudioFrameCount(count), at: nil,
                    completionCallbackType: .dataPlayedBack, completionHandler: played)
            case .silence, .fadeOut:
                guard let buffer = buffers[index] else { throw Failure.noBuffer }
                node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack,
                                    completionHandler: played)
            }
        }
        self.engine = engine
        self.node = node
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInterruption?() }
        }
        attachTap()
        try engine.start()
        node.play()
    }

    func installTap(_ handler: @escaping @Sendable (AlarmRenderedBuffer) -> Void) {
        removeTap()
        tapHandler = handler
        attachTap()
    }

    func removeTap() {
        tapHandler = nil
        if isTapped {
            engine?.mainMixerNode.removeTap(onBus: 0)
            isTapped = false
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        removeTap()
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }

    private func attachTap() {
        guard let engine, let tapHandler, !isTapped else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil, block: Self.tapBlock(tapHandler))
        isTapped = true
    }

    // MARK: Pieces that run off the main actor, or need no engine

    /// The node's completion handler. It's made outside the main actor because the node calls it on its own
    /// thread; it hands the report to the main queue, which keeps them in order.
    private nonisolated static func completion(
        _ report: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in DispatchQueue.main.async { MainActor.assumeIsolated { report() } } }
    }

    /// The mixer tap's block, made outside the main actor because the tap calls it on its own thread.
    private nonisolated static func tapBlock(
        _ handler: @escaping @Sendable (AlarmRenderedBuffer) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            if let rendered = rendered(buffer, hostTime: hostTime) { handler(rendered) }
        }
    }

    /// `frames` of silence in `format`.
    nonisolated static func silentBuffer(format: AVAudioFormat, frames: Int) throws -> AVAudioPCMBuffer {
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw Failure.noBuffer }
        buffer.frameLength = AVAudioFrameCount(frames)
        // A new buffer's memory isn't promised to be zero.
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
        }
        return buffer
    }

    /// The sound's frames `start ..< start + count`, fading out along a half cosine to exact silence.
    nonisolated static func fadedBuffer(from file: AVAudioFile, start: Int, count: Int) throws -> AVAudioPCMBuffer {
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { throw Failure.noBuffer }
        file.framePosition = AVAudioFramePosition(start)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard let channels = buffer.floatChannelData else { throw Failure.noBuffer }
        let frames = Int(buffer.frameLength)
        for frame in 0..<frames {
            let gain = Float(0.5 + 0.5 * cos(Double.pi * Double(frame + 1) / Double(frames)))
            for channel in 0..<Int(buffer.format.channelCount) { channels[channel][frame] *= gain }
        }
        return buffer
    }

    /// A tap buffer as interleaved samples, or nil when it isn't Float32 or holds nothing.
    nonisolated static func rendered(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) -> AlarmRenderedBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channelCount > 0, frames > 0, let data = buffer.floatChannelData else { return nil }
        var samples = [Float](repeating: 0, count: frames * channelCount)
        if buffer.format.isInterleaved {
            for index in samples.indices { samples[index] = data[0][index] }
        } else {
            for channel in 0..<channelCount {
                for frame in 0..<frames { samples[frame * channelCount + channel] = data[channel][frame] }
            }
        }
        return AlarmRenderedBuffer(
            samples: samples, sampleRate: buffer.format.sampleRate, channelCount: channelCount, hostTime: hostTime)
    }
}
