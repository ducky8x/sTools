import Foundation
import STPlatform

/// Reports the free space of the volume that holds a recording. Injected so tests can fake a full disk.
public protocol FreeSpaceProvider: Sendable {
    func freeBytes(at url: URL) -> Int64
}

/// Reads the real free space of the volume containing the URL.
public struct VolumeFreeSpaceProvider: FreeSpaceProvider {
    public init() {}

    public func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? Int.max)
    }
}

/// Everything the writer needs to create files.
public struct WriterConfiguration: Sendable {
    public static let defaultHardFloorBytes: Int64 = 512 * 1024 * 1024

    public var directory: URL
    /// File name without extension. The first file is `<baseName>.mov`, later parts `<baseName> part 2.mov`.
    public var baseName: String
    /// Size of the composited frames. Odd sides are rounded down to even.
    public var canvas: PixelSize
    public var frameRate: Int
    public var codec: VideoCodec
    public var quality: VideoQuality
    /// Media seconds after which the writer continues in a new file, or nil for one file.
    public var splitIntervalSeconds: TimeInterval?
    public var lowDiskWarningBytes: Int64
    /// Below this the writer stops and finalizes the file.
    public var hardFloorBytes: Int64
    /// Names of the audio tracks in file order: the mix first, then each source. Empty for a silent recording.
    public var audioTrackNames: [String]

    public init(
        directory: URL,
        baseName: String,
        canvas: PixelSize,
        frameRate: Int = 60,
        codec: VideoCodec = .h264,
        quality: VideoQuality = .automatic,
        splitIntervalSeconds: TimeInterval? = nil,
        lowDiskWarningBytes: Int64 = 10 * 1_073_741_824,
        hardFloorBytes: Int64 = WriterConfiguration.defaultHardFloorBytes,
        audioTrackNames: [String] = []
    ) {
        self.directory = directory
        self.baseName = baseName
        self.canvas = canvas
        self.frameRate = frameRate
        self.codec = codec
        self.quality = quality
        self.splitIntervalSeconds = splitIntervalSeconds
        self.lowDiskWarningBytes = lowDiskWarningBytes
        self.hardFloorBytes = hardFloorBytes
        self.audioTrackNames = audioTrackNames
    }

    /// Builds a configuration from the user's settings. The folder defaults to the options' folder.
    public init(
        options: RecordingOptions,
        baseName: String,
        canvas: PixelSize,
        audioTrackNames: [String],
        directory: URL? = nil
    ) {
        self.init(
            directory: directory ?? options.folderURL,
            baseName: baseName,
            canvas: canvas,
            frameRate: options.frameRate.framesPerSecond,
            codec: options.codec,
            quality: options.quality,
            splitIntervalSeconds: options.split == .off ? nil : TimeInterval(options.split.minutes * 60),
            lowDiskWarningBytes: Int64(options.lowDiskWarningGB * 1_073_741_824),
            audioTrackNames: audioTrackNames)
    }
}

/// Why a recording ended.
public enum WriterStopReason: Sendable, Equatable {
    case finished
    case lowDisk
    case failed(String)
}

public struct WriterResult: Sendable, Equatable {
    /// Finished files in recording order.
    public var files: [URL]
    public var framesWritten: Int
    public var droppedFrames: Int
    public var droppedAudioChunks: Int
    public var stopReason: WriterStopReason
}

public enum WriterEvent: Sendable, Equatable {
    case segmentStarted(index: Int, url: URL)
    case segmentFinished(index: Int, url: URL)
    case lowDiskWarning(freeBytes: Int64)
    /// Free space fell under the hard floor; the writer has stopped and is finalizing.
    case stoppedForLowDisk(freeBytes: Int64)
    case failed(String)
    case finished(WriterResult)
}

/// What happened to a frame handed to the writer.
public enum FrameDisposition: Sendable, Equatable {
    case written
    /// The encoder was not ready (or the frame was unusable); the frame was counted and discarded.
    case dropped
    /// The writer is not recording (never started, stopped, or failed).
    case stopped
}

public enum RecordingWriterError: Error, Equatable {
    case alreadyStarted
    case invalidConfiguration(String)
    case fileExists(URL)
    case writerFailed(String)
}
