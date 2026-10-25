import CoreMedia
import CoreVideo
import Foundation
import os

/// One recording: the frame clock composites the rig's latest frames into the writer at the output rate, and
/// the sound collected since the last tick goes in alongside (spec 5.4.2).
public final class RecordingSession: @unchecked Sendable {
    /// Audio is written this far behind the video clock, so sources that deliver a little late are not padded
    /// with silence and then trimmed.
    public static let audioLag = 0.25

    public struct Configuration: Sendable {
        public var layout: RecordingLayout
        public var options: RecordingOptions
        public var canvas: PixelSize
        public var baseName: String
        /// Where the .mov is written; the options' folder when nil.
        public var directory: URL?
        /// The in-process feeds that wanted recording when it started (`InProcessAudioFeed.wantsRecording`), each a
        /// track after the layout's sources for the whole recording.
        public var feeds: [String]
        /// Media seconds after which the recording continues in a new file; the options' split when nil. Tests split
        /// a short recording with it.
        var splitIntervalSeconds: TimeInterval?

        public init(layout: RecordingLayout, options: RecordingOptions, canvas: PixelSize, baseName: String,
                    directory: URL? = nil, feeds: [String] = []) {
            self.layout = layout
            self.options = options
            self.canvas = canvas
            self.baseName = baseName
            self.directory = directory
            self.feeds = feeds
        }

        public var outputSize: PixelSize { LayoutMath.outputSize(options.outputSize, canvas: canvas) }
    }

    public let configuration: Configuration
    public let tracks: [AudioSourceTrack]
    public var writerEvents: AsyncStream<WriterEvent> { writer.events }

    private let rig: CaptureRig
    private let writer: RecordingWriter
    /// Draws each frame: the one readied while the tool was armed (`RecordingWarmUp`) when it's for this output size.
    let compositor: Compositor
    private let clock: any MediaClock
    private let driver: any TickDriver
    private var frameClock: FrameClock?
    private var bus: AudioMixBus?
    private let state = OSAllocatedUnfairLock(initialState: TickState())
    /// Held for a whole tick. `stop()` takes it too, so a tick already running when Stop is pressed finishes
    /// first and none runs after: otherwise a late tick could write older sound after the final block.
    private let tickGate = NSLock()
    private var isStopped = false
    /// The picture the last drawing tick made and the sources it shows. A tick whose sources brought nothing new
    /// writes it again instead of drawing the same picture once more (a still screen, Minecraft closed). Touched only by
    /// `tick`, under `tickGate`.
    private var lastPicture: CVPixelBuffer?
    private var lastPictureSources: Set<SourceKey> = []
    /// A source brought a frame, or came or went, since `lastPicture` was drawn. It stays set across ticks the
    /// encoder was too busy to take, so the next one draws.
    private var sourcesChanged = true

    private struct TickState {
        var lastTick: FrameTick?
        var skippedSlots = 0
        var compositorMisses = 0
        /// Ticks skipped because the encoder wasn't ready; nothing was drawn for them.
        var encoderBusy = 0
        /// Pictures drawn, of them the ones handed on without drawing (`Compositor.passThrough`), and ticks that wrote
        /// the last picture again because nothing had changed.
        var drawn = 0
        var passedThrough = 0
        var reused = 0
    }

    public init(
        configuration: Configuration, rig: CaptureRig, clock: any MediaClock = HostMediaClock(),
        driver: (any TickDriver)? = nil, freeSpace: any FreeSpaceProvider = VolumeFreeSpaceProvider(),
        compositor warmed: Compositor? = nil
    ) throws {
        self.configuration = configuration
        self.rig = rig
        self.clock = clock
        self.driver = driver ?? DispatchTickDriver(queue: DispatchQueue(label: "sTools.recording.frames", qos: .userInteractive))
        let output = configuration.outputSize
        tracks = AudioSourceTrack.tracks(for: configuration.layout, feeds: configuration.feeds)
            .filter { rig.audioTracks.contains($0.id) }
        let trackNames = tracks.isEmpty ? [] : [AudioSourceTrack.mixTitle] + tracks.map(\.title)
        var writerConfiguration = WriterConfiguration(
            options: configuration.options, baseName: configuration.baseName, canvas: output,
            audioTrackNames: trackNames, directory: configuration.directory)
        writerConfiguration.canvas = output
        if let split = configuration.splitIntervalSeconds { writerConfiguration.splitIntervalSeconds = split }
        writer = RecordingWriter(configuration: writerConfiguration, freeSpace: freeSpace)
        if let warmed, warmed.outputSize == output.evenSized {
            compositor = warmed
        } else {
            compositor = try Compositor(outputSize: output)
        }
    }

    /// Starts writing now.
    public func start() throws {
        let origin = clock.now()
        try writer.start(at: .zero)
        let bus = AudioMixBus(origin: origin, tracks: tracks)
        self.bus = bus
        rig.attach(bus)
        let frameClock = FrameClock(
            framesPerSecond: configuration.options.frameRate.framesPerSecond, clock: clock, driver: driver
        ) { [weak self] tick in self?.tick(tick) }
        self.frameClock = frameClock
        frameClock.start(origin: origin)
    }

    /// Stops the frame clock: no frame is drawn or written after this returns (a tick already running finishes first).
    /// `stop()` does it too; calling it first ends the picture right at a press.
    public func stopTicking() {
        frameClock?.stop()
        tickGate.withLock { isStopped = true }
    }

    /// Stops ticking, writes the last of the sound, and finalizes the file(s).
    public func stop() async -> WriterResult {
        stopTicking()
        let last = state.withLock { $0.lastTick }
        if let last, let bus {
            // Give late sound its lag's worth of time to arrive, then close every track at the last frame's end.
            try? await Task.sleep(for: .seconds(Self.audioLag))
            let end = CMTimeAdd(last.hostTime, CMTime(value: 1, timescale: CMTimeScale(configuration.options.frameRate.framesPerSecond)))
            if let block = bus.finish(at: end) { write(block) }
        }
        if let bus { rig.detach(bus) }
        return await writer.finish()
    }

    // MARK: Live readouts

    public var elapsedSeconds: Double { state.withLock { $0.lastTick.map { CMTimeGetSeconds($0.time) } ?? 0 } }
    public var currentFileSize: Int64 { writer.currentFileSize }
    /// Frames the encoder or the compositor couldn't take, plus slots the clock missed.
    public var droppedFrames: Int {
        let local = state.withLock { $0.skippedSlots + $0.compositorMisses + $0.encoderBusy }
        return writer.droppedFrameCount + local
    }

    /// Pictures the compositor drew, and ticks that wrote the last one again because no source had changed.
    var picturesDrawn: Int { state.withLock { $0.drawn } }
    var picturesPassedThrough: Int { state.withLock { $0.passedThrough } }
    var picturesReused: Int { state.withLock { $0.reused } }

    // MARK: Ticking

    private func tick(_ tick: FrameTick) {
        tickGate.lock()
        defer { tickGate.unlock() }
        guard !isStopped else { return }
        state.withLock {
            $0.lastTick = tick
            $0.skippedSlots += tick.skippedSlots
        }
        let snapshot = rig.hub.snapshot()
        let sources = Set(snapshot.frames.keys)
        if sources != lastPictureSources || snapshot.frames.values.contains(where: \.isNew) { sourcesChanged = true }
        if writer.canAcceptFrame {
            if !sourcesChanged, let lastPicture {
                // The same frames make the same picture: write it again rather than draw it again.
                writer.append(frame: lastPicture, at: tick.time)
                state.withLock { $0.reused += 1 }
            } else if let (picture, passedThrough) = draw(snapshot) {
                writer.append(frame: picture, at: tick.time)
                lastPicture = picture
                lastPictureSources = sources
                sourcesChanged = false
                state.withLock {
                    $0.drawn += 1
                    if passedThrough { $0.passedThrough += 1 }
                }
            } else {
                state.withLock { $0.compositorMisses += 1 }
            }
        } else {
            state.withLock { $0.encoderBusy += 1 }
        }
        if let bus, let block = bus.drain(upTo: CMTimeSubtract(tick.hostTime, CMTime(seconds: Self.audioLag, preferredTimescale: 1_000_000))) {
            write(block)
        }
    }

    /// The snapshot's frames as one output picture, and whether it's a captured frame handed on as it is (the layout
    /// shows one source unchanged over the whole output: Minecraft alone, at the output size); nil if the compositor
    /// had no buffer free.
    private func draw(_ snapshot: FrameSnapshot) -> (CVPixelBuffer, passedThrough: Bool)? {
        let frames = snapshot.frames.mapValues(\.frame)
        let plan = CompositionPlan.make(
            layout: configuration.layout, canvas: configuration.canvas, output: compositor.outputSize,
            frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        if let frame = compositor.passThrough(plan, frames: frames) { return (frame, true) }
        return compositor.render(plan, frames: frames).map { ($0, false) }
    }

    private func write(_ block: AudioBlock) {
        guard !tracks.isEmpty else { return }
        let time = CMTime(value: block.startFrame, timescale: CMTimeScale(AudioFormat.sampleRate))
        writer.append(audio: TrackAudio(track: 0, time: time, samples: block.mix))
        for (index, track) in tracks.enumerated() {
            let samples = block.tracks[track.id] ?? [Float](repeating: 0, count: block.frameCount * AudioFormat.channelCount)
            writer.append(audio: TrackAudio(track: index + 1, time: time, samples: samples))
        }
    }
}
