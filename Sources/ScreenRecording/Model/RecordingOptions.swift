import Foundation
import STPlatform

public enum FrameRate: Int, Codable, CaseIterable, Sendable {
    case fps60 = 60
    case fps30 = 30

    public var framesPerSecond: Int { rawValue }
}

public enum OutputSize: String, Codable, CaseIterable, Sendable {
    case native
    case p1440
    case p1080

    /// The height the output is scaled down to, or nil to keep the canvas size.
    public var targetHeight: Int? {
        switch self {
        case .native: nil
        case .p1440: 1440
        case .p1080: 1080
        }
    }
}

public enum RecordingFileType: String, Codable, CaseIterable, Sendable {
    case mp4
    case mov

    public var fileExtension: String { rawValue }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc
}

public enum Countdown: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case threeSeconds = 3
    case fiveSeconds = 5

    public var seconds: Int { rawValue }
}

public enum SplitInterval: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case thirtyMinutes = 30
    case sixtyMinutes = 60
    case twoHours = 120

    public var minutes: Int { rawValue }
}

public enum MinimizedWindowBehavior: String, Codable, CaseIterable, Sendable {
    case holdLastFrame
    case showNothing
}

/// How the canvas size is chosen.
public enum CanvasSize: Equatable, Sendable, Codable {
    /// The pixel size of the display Minecraft is on.
    case minecraftDisplay
    case custom(PixelSize)

    private enum CodingKeys: String, CodingKey { case kind, width, height }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "custom":
            self = .custom(PixelSize(
                width: try container.decode(Int.self, forKey: .width),
                height: try container.decode(Int.self, forKey: .height)))
        default:
            self = .minecraftDisplay
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .minecraftDisplay:
            try container.encode("minecraftDisplay", forKey: .kind)
        case .custom(let size):
            try container.encode("custom", forKey: .kind)
            try container.encode(size.width, forKey: .width)
            try container.encode(size.height, forKey: .height)
        }
    }
}

/// Video quality: let sTools choose a bit rate, or set a 0...1 quality.
public enum VideoQuality: Equatable, Sendable, Codable {
    case automatic
    case manual(Double)

    private enum CodingKeys: String, CodingKey { case mode, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .mode) {
        case "manual":
            let value = try container.decodeIfPresent(Double.self, forKey: .value) ?? 0.7
            self = .manual(value.isFinite ? min(1, max(0, value)) : 0.7)
        default:
            self = .automatic
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode("automatic", forKey: .mode)
        case .manual(let value):
            try container.encode("manual", forKey: .mode)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Every Screen Recording setting (spec 5.4.5). Stored as the `recording` settings document.
/// Loading is tolerant: a missing or unusable key falls back to its default, and numeric values are clamped.
public struct RecordingOptions: SettingsDocument {
    public static let name = "recording"
    public static let version = 1
    public static var defaultValue: RecordingOptions { RecordingOptions() }

    public static let canvasSideRange = 64...16384
    public static let lowDiskRangeGB = 1.0...1000.0

    /// Absolute path of the output folder. Defaults to `~/Movies/sTools`.
    public var folderPath: String
    public var frameRate: FrameRate
    public var outputSize: OutputSize
    public var fileType: RecordingFileType
    public var canvas: CanvasSize
    public var codec: VideoCodec
    public var quality: VideoQuality
    public var showCursor: Bool
    public var askSaveDelete: Bool
    public var countdown: Countdown
    public var split: SplitInterval
    public var lowDiskWarningGB: Double
    public var livePreview: Bool
    public var minimizedWindowBehavior: MinimizedWindowBehavior

    public init(
        folderPath: String = RecordingOptions.defaultFolderPath,
        frameRate: FrameRate = .fps60,
        outputSize: OutputSize = .native,
        fileType: RecordingFileType = .mp4,
        canvas: CanvasSize = .minecraftDisplay,
        codec: VideoCodec = .h264,
        quality: VideoQuality = .automatic,
        showCursor: Bool = true,
        askSaveDelete: Bool = true,
        countdown: Countdown = .off,
        split: SplitInterval = .off,
        lowDiskWarningGB: Double = 10,
        livePreview: Bool = true,
        minimizedWindowBehavior: MinimizedWindowBehavior = .holdLastFrame
    ) {
        self.folderPath = folderPath
        self.frameRate = frameRate
        self.outputSize = outputSize
        self.fileType = fileType
        self.canvas = canvas
        self.codec = codec
        self.quality = quality
        self.showCursor = showCursor
        self.askSaveDelete = askSaveDelete
        self.countdown = countdown
        self.split = split
        self.lowDiskWarningGB = lowDiskWarningGB
        self.livePreview = livePreview
        self.minimizedWindowBehavior = minimizedWindowBehavior
        clamp()
    }

    public static var defaultFolderPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Movies/sTools")
    }

    public var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    /// Pulls every value back into its legal range.
    public mutating func clamp() {
        if folderPath.trimmingCharacters(in: .whitespaces).isEmpty { folderPath = Self.defaultFolderPath }
        if folderPath.hasPrefix("~") { folderPath = (folderPath as NSString).expandingTildeInPath }
        if !lowDiskWarningGB.isFinite { lowDiskWarningGB = 10 }
        lowDiskWarningGB = min(Self.lowDiskRangeGB.upperBound, max(Self.lowDiskRangeGB.lowerBound, lowDiskWarningGB))
        if case .custom(let size) = canvas {
            canvas = .custom(PixelSize(
                width: min(Self.canvasSideRange.upperBound, max(Self.canvasSideRange.lowerBound, size.width)),
                height: min(Self.canvasSideRange.upperBound, max(Self.canvasSideRange.lowerBound, size.height))))
        }
        if case .manual(let value) = quality {
            quality = .manual(value.isFinite ? min(1, max(0, value)) : 0.7)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case folderPath, frameRate, outputSize, fileType, canvas, codec, quality, showCursor
        case askSaveDelete, countdown, split, lowDiskWarningGB, livePreview, minimizedWindowBehavior
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingOptions()
        self.init(
            folderPath: c.value(.folderPath, d.folderPath),
            frameRate: c.value(.frameRate, d.frameRate),
            outputSize: c.value(.outputSize, d.outputSize),
            fileType: c.value(.fileType, d.fileType),
            canvas: c.value(.canvas, d.canvas),
            codec: c.value(.codec, d.codec),
            quality: c.value(.quality, d.quality),
            showCursor: c.value(.showCursor, d.showCursor),
            askSaveDelete: c.value(.askSaveDelete, d.askSaveDelete),
            countdown: c.value(.countdown, d.countdown),
            split: c.value(.split, d.split),
            lowDiskWarningGB: c.value(.lowDiskWarningGB, d.lowDiskWarningGB),
            livePreview: c.value(.livePreview, d.livePreview),
            minimizedWindowBehavior: c.value(.minimizedWindowBehavior, d.minimizedWindowBehavior))
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `fallback` when the key is missing or unusable.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
