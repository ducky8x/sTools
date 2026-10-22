import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Writes composited frames and audio into a fragmented QuickTime movie (spec 5.4.2).
///
/// Call `start(at:)`, then `append(frame:at:)` and `append(audio:)` from any thread, then `finish()`.
/// Nothing ever queues: a frame that finds the encoder busy is dropped and counted.
public final class RecordingWriter: @unchecked Sendable {
    public static let fragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    private static let diskCheckInterval = CMTime(seconds: 1, preferredTimescale: 600)
    /// How long a part that was split off waits for the rest of its sound once the picture has moved on: the session
    /// writes sound a quarter second behind the picture (`RecordingSession.audioLag`), so this leaves room to spare. A
    /// part closes sooner, as soon as every track's sound has passed its cut.
    static let lateSoundAllowance = CMTime(seconds: 1, preferredTimescale: 600)

    public let events: AsyncStream<WriterEvent>

    private let configuration: WriterConfiguration
    private let canvas: PixelSize
    private let freeSpace: any FreeSpaceProvider
    private let readinessOverride: (@Sendable () -> Bool)?
    private let allowsHardwareEncoder: Bool
    private let continuation: AsyncStream<WriterEvent>.Continuation
    private let lock = NSLock()

    private enum Phase { case idle, recording, stopped(WriterStopReason) }

    private var phase = Phase.idle
    private var segment: Segment?
    /// The part split off last, while it still takes the sound up to its cut (`lateSoundAllowance`): its picture has
    /// ended there and the next part's has begun.
    private var closing: ClosingSegment?
    private var segmentIndex = 0
    /// The name the files are written under: the configuration's, or the next free one when a recording in the folder
    /// holds it (`RecordingNames`). Chosen at `start`.
    private var baseName = ""
    private var finishedFiles: [URL] = []
    private var finalizers: [Task<Void, Never>] = []
    private var lastVideoTime: CMTime?
    private var lastAudioEnd: [Int: CMTime] = [:]
    private var nextDiskCheck: CMTime?
    private var warnedLowDisk = false
    private var framesWritten = 0
    private var droppedFrames = 0
    private var droppedAudioChunks = 0
    private var audioFormat: CMAudioFormatDescription?

    /// `readinessOverride` lets tests simulate a stalled encoder input; `allowsHardwareEncoder: false` limits them to
    /// the software encoders (the H.264 one takes no constant quality, like Intel Macs' encoders).
    init(
        configuration: WriterConfiguration,
        freeSpace: any FreeSpaceProvider,
        readinessOverride: (@Sendable () -> Bool)?,
        allowsHardwareEncoder: Bool = true
    ) {
        self.configuration = configuration
        self.canvas = configuration.canvas.evenSized
        self.freeSpace = freeSpace
        self.readinessOverride = readinessOverride
        self.allowsHardwareEncoder = allowsHardwareEncoder
        let (stream, continuation) = AsyncStream<WriterEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    public convenience init(configuration: WriterConfiguration, freeSpace: any FreeSpaceProvider = VolumeFreeSpaceProvider()) {
        self.init(configuration: configuration, freeSpace: freeSpace, readinessOverride: nil)
    }

    // MARK: Public state

    public var droppedFrameCount: Int { locked { droppedFrames } }
    public var writtenFrameCount: Int { locked { framesWritten } }
    public var droppedAudioChunkCount: Int { locked { droppedAudioChunks } }

    /// The file being written right now, nil before `start` and after the writer stopped.
    public var currentFileURL: URL? { locked { segment?.url } }

    /// Bytes on disk of the file being written, for the on-page file size readout.
    public var currentFileSize: Int64 {
        guard let url = currentFileURL else { return 0 }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return Int64(size ?? 0)
    }

    /// True when a frame appended now would not be dropped. The compositor can skip rendering when false.
    public var canAcceptFrame: Bool {
        locked {
            guard case .recording = phase, let segment else { return false }
            return segment.video.isReadyForMoreMediaData && (readinessOverride?() ?? true)
        }
    }

    // MARK: Lifecycle

    /// Creates the first file. `time` is the media time of the first frame.
    public func start(at time: CMTime) throws {
        try locked {
            guard case .idle = phase else { throw RecordingWriterError.alreadyStarted }
            guard configuration.frameRate > 0, !configuration.canvas.isEmpty else {
                throw RecordingWriterError.invalidConfiguration("frame rate and canvas must be positive")
            }
            try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
            baseName = RecordingNames.freeBase(configuration.baseName, in: configuration.directory)
            segmentIndex = 1
            segment = try makeSegment(index: 1, start: time)
            phase = .recording
            nextDiskCheck = time
        }
        if let url = currentFileURL { continuation.yield(.segmentStarted(index: 1, url: url)) }
    }

    /// Finalizes the files and ends the event stream.
    public func finish() async -> WriterResult {
        let pending: [Task<Void, Never>] = locked {
            if case .recording = phase { phase = .stopped(.finished) }
            closeSplitOffPart()
            if let segment {
                finalize(segment, endTime: segment.lastEnd)
                self.segment = nil
            }
            return finalizers
        }
        for task in pending { await task.value }
        let result = locked { makeResult() }
        continuation.yield(.finished(result))
        continuation.finish()
        return result
    }

    // MARK: Video

    @discardableResult
    public func append(frame: CVPixelBuffer, at time: CMTime) -> FrameDisposition {
        var events: [WriterEvent] = []
        let disposition: FrameDisposition = locked {
            guard case .recording = phase, var current = segment else { return .stopped }
            if let last = lastVideoTime, time <= last { return countDroppedFrame() }
            lastVideoTime = time
            guard CVPixelBufferGetWidth(frame) == canvas.width, CVPixelBufferGetHeight(frame) == canvas.height else {
                return countDroppedFrame()
            }
            if checkDisk(at: time, events: &events) { return .stopped }
            if let closing, time - closing.cut >= Self.lateSoundAllowance { closeSplitOffPart() }
            if let interval = configuration.splitIntervalSeconds,
               (time - current.start).seconds >= interval {
                do {
                    splitOff(current, at: time)
                    segmentIndex += 1
                    current = try makeSegment(index: segmentIndex, start: time)
                    segment = current
                    events.append(.segmentStarted(index: segmentIndex, url: current.url))
                } catch {
                    stop(.failed(String(describing: error)), events: &events)
                    return .stopped
                }
            }
            guard current.video.isReadyForMoreMediaData, readinessOverride?() ?? true else {
                return countDroppedFrame()
            }
            guard current.adaptor.append(frame, withPresentationTime: time) else {
                stop(.failed(current.writer.error?.localizedDescription ?? "video append failed"), events: &events)
                return .stopped
            }
            current.lastEnd = time + CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
            segment = current
            framesWritten += 1
            if framesWritten == 1 { events.append(.firstFrameWritten) }
            return .written
        }
        for event in events { continuation.yield(event) }
        return disposition
    }

    // MARK: Audio

    /// Appends a chunk to its track. Returns false if the chunk was discarded.
    ///
    /// Sound from before the last split's cut goes to the part split off there, which takes it until every track has
    /// passed the cut; a chunk that spans the cut is divided at it, so the parts meet with no gap and no overlap.
    @discardableResult
    public func append(audio chunk: TrackAudio) -> Bool {
        var events: [WriterEvent] = []
        let accepted: Bool = locked {
            guard case .recording = phase, let current = segment else { return false }
            guard chunk.frameCount > 0, current.audio.indices.contains(chunk.track) else {
                droppedAudioChunks += 1
                return false
            }
            if let last = lastAudioEnd[chunk.track], chunk.time < last { return countDroppedAudio() }
            var rest = chunk
            if var closing, chunk.time < closing.cut {
                let (before, after) = chunk.divided(at: closing.cut)
                if let before {
                    switch write(before, to: &closing.segment, events: &events) {
                    case .written: break
                    case .dropped: return countDroppedAudio()
                    case .failed: return false
                    }
                    self.closing = closing
                }
                if closing.hasSoundUpToItsCut(lastAudioEnd) { closeSplitOffPart() }
                guard let after else { return true }
                rest = after
            }
            if rest.endTime <= current.start { return countDroppedAudio() }
            var written = current
            switch write(rest, to: &written, events: &events) {
            case .written:
                // The file ends with whichever runs longer, so sound past the last written frame (frames the
                // encoder dropped at the end) isn't cut off.
                if rest.endTime > written.lastEnd { written.lastEnd = rest.endTime }
                segment = written
                return true
            case .dropped: return countDroppedAudio()
            case .failed: return false
            }
        }
        for event in events { continuation.yield(event) }
        return accepted
    }

    private enum AudioWrite { case written, dropped, failed }

    /// Appends `chunk` to its track in `segment`; a failure stops the writer.
    private func write(_ chunk: TrackAudio, to segment: inout Segment, events: inout [WriterEvent]) -> AudioWrite {
        let input = segment.audio[chunk.track]
        guard input.isReadyForMoreMediaData, let buffer = makeSampleBuffer(chunk) else { return .dropped }
        guard input.append(buffer) else {
            stop(.failed(segment.writer.error?.localizedDescription ?? "audio append failed"), events: &events)
            return .failed
        }
        lastAudioEnd[chunk.track] = chunk.endTime
        return .written
    }

    // MARK: Internals (all require the lock)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func countDroppedFrame() -> FrameDisposition {
        droppedFrames += 1
        return .dropped
    }

    private func countDroppedAudio() -> Bool {
        droppedAudioChunks += 1
        return false
    }

    private func makeResult() -> WriterResult {
        let reason: WriterStopReason
        if case .stopped(let stopReason) = phase { reason = stopReason } else { reason = .finished }
        return WriterResult(
            files: finishedFiles,
            framesWritten: framesWritten,
            droppedFrames: droppedFrames,
            droppedAudioChunks: droppedAudioChunks,
            stopReason: reason)
    }

    /// Returns true if the writer stopped for lack of disk space.
    private func checkDisk(at time: CMTime, events: inout [WriterEvent]) -> Bool {
        guard let due = nextDiskCheck, time >= due else { return false }
        nextDiskCheck = time + Self.diskCheckInterval
        let free = freeSpace.freeBytes(at: configuration.directory)
        if free < configuration.hardFloorBytes {
            events.append(.stoppedForLowDisk(freeBytes: free))
            stop(.lowDisk, events: &events, announce: false)
            return true
        }
        if free < configuration.lowDiskWarningBytes, !warnedLowDisk {
            warnedLowDisk = true
            events.append(.lowDiskWarning(freeBytes: free))
        }
        return false
    }

    private func stop(_ reason: WriterStopReason, events: inout [WriterEvent], announce: Bool = true) {
        phase = .stopped(reason)
        closeSplitOffPart()
        if let segment {
            finalize(segment, endTime: segment.lastEnd)
            self.segment = nil
        }
        if announce, case .failed(let message) = reason { events.append(.failed(message)) }
    }

    private func makeSegment(index: Int, start: CMTime) throws -> Segment {
        // The name was free at the start; a part's name that turned up in the folder since takes the next free one.
        let url = RecordingNames.freeURL(RecordingNames.partName(baseName, index: index), fileExtension: "mov", in: configuration.directory)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = Self.fragmentInterval
        writer.shouldOptimizeForNetworkUse = false

        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(for: configuration, allowsHardwareEncoder: allowsHardwareEncoder))
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: canvas.width,
                kCVPixelBufferHeightKey as String: canvas.height,
            ])
        guard writer.canAdd(video) else { throw RecordingWriterError.writerFailed("cannot add video input") }
        writer.add(video)

        var audio: [AVAssetWriterInput] = []
        for name in configuration.audioTrackNames {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = true
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = name as NSString
            title.dataType = kCMMetadataBaseDataType_UTF8 as String
            title.extendedLanguageTag = "und"
            input.metadata = [title]
            guard writer.canAdd(input) else { throw RecordingWriterError.writerFailed("cannot add audio input") }
            writer.add(input)
            audio.append(input)
        }

        guard writer.startWriting() else {
            throw RecordingWriterError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: start)
        return Segment(index: index, url: url, writer: writer, video: video, adaptor: adaptor, audio: audio, start: start)
    }

    /// The video input's settings. Manual quality is a constant quality only where the encoder takes one (Apple
    /// silicon's do). Intel Macs' encoders don't, and AVAssetWriterInput throws an Objective-C exception for the
    /// quality key there, which would end sTools, so on those the quality sets the bit rate instead.
    static func videoSettings(for configuration: WriterConfiguration, allowsHardwareEncoder: Bool) -> [String: Any] {
        let canvas = configuration.canvas.evenSized
        let codec: AVVideoCodecType = configuration.codec == .hevc ? .hevc : .h264
        let encoderSpecification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: allowsHardwareEncoder,
        ]
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
            AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        switch configuration.quality {
        case .automatic:
            compression[AVVideoAverageBitRateKey] = automaticBitRate(
                canvas: canvas, frameRate: configuration.frameRate, codec: configuration.codec)
        case .manual(let value):
            let quality = min(1, max(0, value))
            if encoderTakesConstantQuality(codec: configuration.codec, canvas: canvas, specification: encoderSpecification) {
                compression[AVVideoQualityKey] = quality
            } else {
                compression[AVVideoAverageBitRateKey] = manualBitRate(
                    quality: quality, canvas: canvas, frameRate: configuration.frameRate, codec: configuration.codec)
            }
        }
        if configuration.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: encoderSpecification,
        ]
    }

    /// Whether the encoder VideoToolbox picks for this codec, size and specification takes a constant quality
    /// (`kVTCompressionPropertyKey_Quality`, what `AVVideoQualityKey` sets). False when it can't be told.
    static func encoderTakesConstantQuality(codec: VideoCodec, canvas: PixelSize, specification: [String: Any]) -> Bool {
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(canvas.width), height: Int32(canvas.height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, encoderIDOut: nil, supportedPropertiesOut: &properties)
        guard status == noErr, let supported = properties as? [String: Any] else { return false }
        return supported[kVTCompressionPropertyKey_Quality as String] != nil
    }

    /// Bits per pixel per frame: game footage needs more than talking-head video, HEVC needs about a third less.
    static func automaticBitRate(canvas: PixelSize, frameRate: Int, codec: VideoCodec) -> Int {
        bitRate(canvas: canvas, frameRate: frameRate, codec: codec, scale: 1)
    }

    /// Manual quality as a bit rate, for encoders without a constant quality: 50% is the automatic rate and 100%
    /// twice it.
    static func manualBitRate(quality: Double, canvas: PixelSize, frameRate: Int, codec: VideoCodec) -> Int {
        bitRate(canvas: canvas, frameRate: frameRate, codec: codec, scale: 2 * min(1, max(0, quality)))
    }

    private static func bitRate(canvas: PixelSize, frameRate: Int, codec: VideoCodec, scale: Double) -> Int {
        let bitsPerPixel = codec == .hevc ? 0.07 : 0.1
        let rate = Double(canvas.width * canvas.height * frameRate) * bitsPerPixel * scale
        return min(150_000_000, max(500_000, Int(rate)))
    }

    static var audioSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: TrackAudio.sampleRate,
        AVNumberOfChannelsKey: TrackAudio.channelCount,
        AVEncoderBitRateKey: 160_000,
    ] }

    /// Ends `segment`'s picture at `cut`, where the next part's begins, and keeps it open for the sound up to the cut,
    /// which arrives a little later than the picture. A part without sound tracks closes at once. A part split off
    /// earlier and still waiting for its sound closes first.
    private func splitOff(_ segment: Segment, at cut: CMTime) {
        closeSplitOffPart()
        var ended = segment
        ended.video.markAsFinished()
        ended.videoIsFinished = true
        closing = ClosingSegment(segment: ended, cut: cut)
        if ended.audio.isEmpty || closing?.hasSoundUpToItsCut(lastAudioEnd) == true { closeSplitOffPart() }
    }

    /// Finishes the part split off last, at its cut: whatever sound it hasn't had by now is the next part's or lost.
    private func closeSplitOffPart() {
        guard let closing else { return }
        self.closing = nil
        finalize(closing.segment, endTime: closing.cut)
    }

    /// Closes the segment's inputs and finishes the file in the background; `finish()` awaits every such task.
    private func finalize(_ segment: Segment, endTime: CMTime) {
        let writer = segment.writer
        if !segment.videoIsFinished { segment.video.markAsFinished() }
        for input in segment.audio { input.markAsFinished() }
        writer.endSession(atSourceTime: endTime)
        let url = segment.url
        let index = segment.index
        let box = WriterBox(writer)
        let continuation = continuation
        finalizers.append(Task {
            await box.finish()
            continuation.yield(.segmentFinished(index: index, url: url))
        })
        finishedFiles.append(url)
    }

    private func makeSampleBuffer(_ chunk: TrackAudio) -> CMSampleBuffer? {
        if audioFormat == nil {
            var description = AudioStreamBasicDescription(
                mSampleRate: Float64(TrackAudio.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            audioFormat = format
        }
        guard let format = audioFormat else { return nil }
        let byteCount = chunk.samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = chunk.samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: chunk.frameCount,
            presentationTimeStamp: chunk.time, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}

private struct Segment {
    let index: Int
    let url: URL
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: [AVAssetWriterInput]
    let start: CMTime
    var lastEnd: CMTime
    /// Its picture has ended (it was split off) and only its sound still comes in.
    var videoIsFinished = false

    init(index: Int, url: URL, writer: AVAssetWriter, video: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, audio: [AVAssetWriterInput], start: CMTime) {
        self.index = index
        self.url = url
        self.writer = writer
        self.video = video
        self.adaptor = adaptor
        self.audio = audio
        self.start = start
        self.lastEnd = start
    }
}

/// A part split off at `cut`, still taking the sound up to it.
private struct ClosingSegment {
    var segment: Segment
    let cut: CMTime

    /// Whether every one of its tracks has had its sound up to the cut (`lastAudioEnd`, by track), to the nearest
    /// sample frame.
    func hasSoundUpToItsCut(_ lastAudioEnd: [Int: CMTime]) -> Bool {
        segment.audio.indices.allSatisfy { track in
            lastAudioEnd[track].map { (cut - $0).seconds * Double(TrackAudio.sampleRate) < 0.5 } ?? false
        }
    }
}

private extension TrackAudio {
    /// The part of the chunk before `time` and the rest from `time` on, each nil when empty. `time` falls on the
    /// nearest sample frame.
    func divided(at time: CMTime) -> (before: TrackAudio?, after: TrackAudio?) {
        let frames = Int(((time - self.time).seconds * Double(Self.sampleRate)).rounded())
        guard frames < frameCount else { return (self, nil) }
        guard frames > 0 else { return (nil, self) }
        let before = TrackAudio(track: track, time: self.time, samples: Array(samples[..<(frames * Self.channelCount)]))
        let after = TrackAudio(
            track: track, time: self.time + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(Self.sampleRate)),
            samples: Array(samples[(frames * Self.channelCount)...]))
        return (before, after)
    }
}

/// Carries a writer into a finalizing task; it is touched by nobody else once the segment is closed.
private final class WriterBox: @unchecked Sendable {
    private let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) { self.writer = writer }

    func finish() async {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }
}
