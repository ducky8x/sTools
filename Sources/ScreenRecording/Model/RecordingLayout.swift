import Foundation
import STPlatform

/// Insets that trim a source, as fractions (0..<1) of the source's own width and height.
/// Fractions, not pixels, so a crop survives a window being resized.
public struct CropInsets: Codable, Equatable, Hashable, Sendable {
    public static let zero = CropInsets()
    /// The most a source can be cropped on one axis: at least this fraction stays visible.
    public static let minimumVisibleFraction = 0.02

    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var isZero: Bool { self == .zero }

    /// Insets in pixels of a source that is `sourceSize` big (for the editor's crop fields).
    public func pixels(of sourceSize: PixelSize) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let w = Double(sourceSize.width), h = Double(sourceSize.height)
        return (Int((left * w).rounded()), Int((top * h).rounded()), Int((right * w).rounded()), Int((bottom * h).rounded()))
    }

    /// Builds insets from pixel values typed in the editor.
    public init(left: Int, top: Int, right: Int, bottom: Int, of sourceSize: PixelSize) {
        let w = Double(max(1, sourceSize.width)), h = Double(max(1, sourceSize.height))
        self.init(left: Double(left) / w, top: Double(top) / h, right: Double(right) / w, bottom: Double(bottom) / h)
        self = clamped()
    }

    /// Negative or non-finite values become 0, and an axis never crops away its last 2%.
    public func clamped() -> CropInsets {
        func clean(_ v: Double) -> Double { v.isFinite ? max(0, v) : 0 }
        var l = clean(left), t = clean(top), r = clean(right), b = clean(bottom)
        let room = 1 - Self.minimumVisibleFraction
        if l + r > room { let k = room / (l + r); l *= k; r *= k }
        if t + b > room { let k = room / (t + b); t *= k; b *= k }
        return CropInsets(left: l, top: t, right: r, bottom: b)
    }
}

/// A frame drawn around a source, inside its edge.
public struct SourceBorder: Codable, Equatable, Hashable, Sendable {
    /// Width as a fraction of the canvas's shorter side (`CanvasMapping.length`), so it keeps its look at any
    /// canvas or output size. 0 means no border.
    public var width: Double
    /// `#RRGGBB` or `#RRGGBBAA`.
    public var colorHex: String

    public init(width: Double = 0, colorHex: String = "#FFFFFF") {
        self.width = width
        self.colorHex = colorHex
    }

    public static let none = SourceBorder()
}

public struct WindowReference: Codable, Equatable, Hashable, Sendable {
    /// The `CGWindowID`. Only valid while that window lives; `appName`/`title` re-find it in a later session.
    public var windowID: UInt32
    public var appName: String
    public var bundleID: String?
    public var title: String

    public init(windowID: UInt32, appName: String, bundleID: String? = nil, title: String) {
        self.windowID = windowID
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
    }
}

public struct DisplayReference: Codable, Equatable, Hashable, Sendable {
    public var displayID: UInt32
    public var name: String

    public init(displayID: UInt32, name: String) {
        self.displayID = displayID
        self.name = name
    }
}

public struct CameraReference: Codable, Equatable, Hashable, Sendable {
    public var uniqueID: String
    public var name: String

    public init(uniqueID: String, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

public enum VideoSourceKind: Equatable, Hashable, Sendable, Codable {
    case window(WindowReference)
    case display(DisplayReference)
    case camera(CameraReference)
    /// A web page, rendered off-screen at the size the source is drawn on the canvas.
    case browser(url: String)

    private enum CodingKeys: String, CodingKey { case type, window, display, camera, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "window": self = .window(try c.decode(WindowReference.self, forKey: .window))
        case "display": self = .display(try c.decode(DisplayReference.self, forKey: .display))
        case "camera": self = .camera(try c.decode(CameraReference.self, forKey: .camera))
        case "browser": self = .browser(url: try c.decode(String.self, forKey: .url))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown video source type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .window(let ref):
            try c.encode("window", forKey: .type)
            try c.encode(ref, forKey: .window)
        case .display(let ref):
            try c.encode("display", forKey: .type)
            try c.encode(ref, forKey: .display)
        case .camera(let ref):
            try c.encode("camera", forKey: .type)
            try c.encode(ref, forKey: .camera)
        case .browser(let url):
            try c.encode("browser", forKey: .type)
            try c.encode(url, forKey: .url)
        }
    }
}

/// One video source placed on the canvas.
public struct VideoSource: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: VideoSourceKind
    /// Where the source sits on the canvas, as fractions of the canvas's width and height (top-left origin), so
    /// it keeps its place and size whatever the canvas's pixel size. Its content is fitted inside, aspect kept.
    public var frame: CanvasRect
    public var crop: CropInsets
    /// 0...1.
    public var opacity: Double
    /// As a fraction of the canvas's shorter side (`CanvasMapping.length`).
    public var cornerRadius: Double
    public var border: SourceBorder
    /// Stack order: higher draws on top. Use the layout's reorder methods to change it.
    public var zIndex: Int

    public init(
        id: UUID = UUID(),
        kind: VideoSourceKind,
        frame: CanvasRect,
        crop: CropInsets = .zero,
        opacity: Double = 1,
        cornerRadius: Double = 0,
        border: SourceBorder = .none,
        zIndex: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.crop = crop
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.border = border
        self.zIndex = zIndex
    }

    /// A source placed in pixels of a `canvas`-sized canvas: `frame`, `cornerRadius` and the border's width are
    /// canvas pixels, saved as fractions of that canvas.
    public init(
        id: UUID = UUID(),
        kind: VideoSourceKind,
        frame: PixelRect,
        on canvas: PixelSize,
        crop: CropInsets = .zero,
        opacity: Double = 1,
        cornerRadius: Double = 0,
        border: SourceBorder = .none,
        zIndex: Int = 0
    ) {
        let mapping = CanvasMapping(canvas)
        var border = border
        border.width = mapping.fraction(ofLength: border.width)
        self.init(id: id, kind: kind, frame: mapping.canvasRect(frame), crop: crop, opacity: opacity,
                  cornerRadius: mapping.fraction(ofLength: cornerRadius), border: border, zIndex: zIndex)
    }

    /// A window source, whose window is found again in Add Source's listing when the sources start.
    var isWindow: Bool {
        if case .window = kind { true } else { false }
    }

    /// The frame in pixels of a `canvas`-sized canvas.
    public func pixelFrame(on canvas: PixelSize) -> PixelRect {
        CanvasMapping(canvas).rect(frame)
    }

    /// A short label for lists.
    public var title: String {
        switch kind {
        case .window(let ref): ref.title.isEmpty ? ref.appName : "\(ref.appName) — \(ref.title)"
        case .display(let ref): ref.name
        case .camera(let ref): ref.name
        case .browser(let url): url
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, crop, opacity, cornerRadius, border, zIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.value(.id, UUID()),
            kind: try c.decode(VideoSourceKind.self, forKey: .kind),
            frame: try c.decode(CanvasRect.self, forKey: .frame),
            crop: c.value(.crop, .zero),
            opacity: c.value(.opacity, 1),
            cornerRadius: c.value(.cornerRadius, 0),
            border: c.value(.border, .none),
            zIndex: c.value(.zIndex, 0))
    }
}

public enum AudioSourceKind: Equatable, Hashable, Sendable, Codable {
    /// Every audio process of the app with this bundle ID (helpers such as browser renderers included).
    case app(bundleID: String)
    case microphone(uniqueID: String)
    /// The sound of a browser video source, as the first build's layouts could name it. Nothing makes one now: the
    /// web pages' sound is `RecordingLayout.includesWebPageAudio`, one track for all the pages, since WebKit plays
    /// them in one process. A saved source of this kind still loads and keeps its row in the Sound section, but nothing is
    /// captured for it.
    case browser(videoSourceID: UUID)

    private enum CodingKeys: String, CodingKey { case type, bundleID, uniqueID, videoSourceID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "app": self = .app(bundleID: try c.decode(String.self, forKey: .bundleID))
        case "microphone": self = .microphone(uniqueID: try c.decode(String.self, forKey: .uniqueID))
        case "browser": self = .browser(videoSourceID: try c.decode(UUID.self, forKey: .videoSourceID))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown audio source type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let bundleID):
            try c.encode("app", forKey: .type)
            try c.encode(bundleID, forKey: .bundleID)
        case .microphone(let uniqueID):
            try c.encode("microphone", forKey: .type)
            try c.encode(uniqueID, forKey: .uniqueID)
        case .browser(let id):
            try c.encode("browser", forKey: .type)
            try c.encode(id, forKey: .videoSourceID)
        }
    }
}

/// One audio source and its volume.
public struct AudioSource: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let volumeRange = 0.0...1.5

    public var id: UUID
    public var kind: AudioSourceKind
    /// The track name in the file and the label in the editor.
    public var name: String
    /// 0...1.5, default 1.
    public var volume: Double

    public init(id: UUID = UUID(), kind: AudioSourceKind, name: String, volume: Double = 1) {
        self.id = id
        self.kind = kind
        self.name = name
        self.volume = Self.clampVolume(volume)
    }

    public static func clampVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(volumeRange.upperBound, max(volumeRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, volume }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.value(.id, UUID()),
            kind: try c.decode(AudioSourceKind.self, forKey: .kind),
            name: c.value(.name, "Audio"),
            volume: c.value(.volume, 1))
    }
}

/// The saved canvas layout: video sources, audio sources, and whether Minecraft's own sound is recorded.
/// Stored as the `recordingLayout` settings document.
///
/// Version 2 saves every source's frame, corner radius and border width as fractions of the canvas, so the layout
/// doesn't move or resize when the canvas's pixel size changes. Version 1 saved them in canvas pixels; such a file
/// loads with `holdsLegacyPixels` set until `convertLegacyPixels(canvas:)` turns it into fractions, once.
public struct RecordingLayout: SettingsDocument {
    public static let name = "recordingLayout"
    public static let version = 2
    public static var defaultValue: RecordingLayout { RecordingLayout() }

    public var videoSources: [VideoSource]
    public var audioSources: [AudioSource]
    public var includesMinecraftAudio: Bool
    /// Volume of Minecraft's sound, 0...1.5.
    public var minecraftAudioVolume: Double
    /// Whether the sound of the web pages on the canvas is recorded (on by default; it counts only while a web page is
    /// on the canvas, `recordsWebPageAudio`). One switch, one volume and one track for all the pages: WebKit plays every
    /// web page of an app in one helper process, so one page's sound can't be told from another's.
    public var includesWebPageAudio: Bool
    /// Volume of the web pages' sound, 0...1.5.
    public var webPageAudioVolume: Double
    /// True for a layout read from a version-1 file: its frames, corner radii and border widths still hold the
    /// canvas pixels that file saved. Saved along with them, so they're never mistaken for fractions.
    public private(set) var holdsLegacyPixels = false

    public init(
        videoSources: [VideoSource] = [],
        audioSources: [AudioSource] = [],
        includesMinecraftAudio: Bool = true,
        minecraftAudioVolume: Double = 1,
        includesWebPageAudio: Bool = true,
        webPageAudioVolume: Double = 1
    ) {
        self.videoSources = videoSources
        self.audioSources = audioSources
        self.includesMinecraftAudio = includesMinecraftAudio
        self.minecraftAudioVolume = AudioSource.clampVolume(minecraftAudioVolume)
        self.includesWebPageAudio = includesWebPageAudio
        self.webPageAudioVolume = AudioSource.clampVolume(webPageAudioVolume)
    }

    private enum CodingKeys: String, CodingKey {
        case videoSources, audioSources, includesMinecraftAudio, minecraftAudioVolume, includesWebPageAudio, webPageAudioVolume, legacyPixels
    }

    /// A layout saved before the web pages' sound existed has neither of its keys: the sound is on, at full volume. A
    /// build from before reads a newer file as it always did, ignoring the keys it doesn't know.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            videoSources: c.value(.videoSources, []),
            audioSources: c.value(.audioSources, []),
            includesMinecraftAudio: c.value(.includesMinecraftAudio, true),
            minecraftAudioVolume: c.value(.minecraftAudioVolume, 1),
            includesWebPageAudio: c.value(.includesWebPageAudio, true),
            webPageAudioVolume: c.value(.webPageAudioVolume, 1))
        holdsLegacyPixels = c.value(.legacyPixels, false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoSources, forKey: .videoSources)
        try c.encode(audioSources, forKey: .audioSources)
        try c.encode(includesMinecraftAudio, forKey: .includesMinecraftAudio)
        try c.encode(minecraftAudioVolume, forKey: .minecraftAudioVolume)
        try c.encode(includesWebPageAudio, forKey: .includesWebPageAudio)
        try c.encode(webPageAudioVolume, forKey: .webPageAudioVolume)
        if holdsLegacyPixels { try c.encode(true, forKey: .legacyPixels) }
    }

    // MARK: Web pages' sound

    /// The addresses of the web pages on the canvas, in the order they were added.
    public var webPageAddresses: [String] {
        videoSources.compactMap { source in
            if case .browser(let address) = source.kind { address } else { nil }
        }
    }

    /// A web page is on the canvas.
    public var hasWebPages: Bool { !webPageAddresses.isEmpty }

    /// A recording of this layout has the web pages' sound on a track of its own: a web page is on the canvas and the
    /// sound's switch is on.
    public var recordsWebPageAudio: Bool { includesWebPageAudio && hasWebPages }

    /// What the web pages' track and its row in the Sound section are called: the page's host when there is one web
    /// page (`twitch.tv`), else *Web pages*.
    public var webPageAudioTitle: String {
        let addresses = webPageAddresses
        guard addresses.count == 1, let address = addresses.first else { return "Web pages" }
        return Self.pageTitle(forAddress: address)
    }

    /// A web address by its host, lower case and without a leading `www.`; *Web page* when it has none.
    static func pageTitle(forAddress address: String) -> String {
        guard let host = URL(string: address)?.host?.lowercased(), !host.isEmpty else { return "Web page" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Version 1 saved frames, corner radii and border widths in pixels of a canvas it didn't record. The file
    /// alone can't say which canvas that was, so the values are marked here and converted by
    /// `convertLegacyPixels(canvas:)` once the canvas is known.
    public static func migrate(from oldVersion: Int, _ raw: [String: Any]) throws -> [String: Any] {
        var raw = raw
        if oldVersion == 1 { raw[CodingKeys.legacyPixels.rawValue] = true }
        return raw
    }

    /// Turns a version-1 layout's canvas pixels into fractions of the canvas it was made on, then clears
    /// `holdsLegacyPixels`. Lossy: that canvas is a best guess (see `legacyCanvas(holding:current:)`). Does nothing
    /// to a layout already in fractions.
    public mutating func convertLegacyPixels(canvas: PixelSize) {
        guard holdsLegacyPixels else { return }
        let pixelFrames = videoSources.map { PixelRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
        let mapping = CanvasMapping(Self.legacyCanvas(holding: pixelFrames, current: canvas))
        for i in videoSources.indices {
            videoSources[i].frame = mapping.canvasRect(pixelFrames[i])
            videoSources[i].cornerRadius = mapping.fraction(ofLength: videoSources[i].cornerRadius)
            videoSources[i].border.width = mapping.fraction(ofLength: videoSources[i].border.width)
        }
        holdsLegacyPixels = false
        sanitize()
    }

    /// The canvas a version-1 layout was most likely made on: `current` (the canvas sTools would use now), or, when
    /// frames reach past it, the smallest whole multiple of it that holds them all. Every edit kept the frames
    /// inside the canvas of the moment, so frames past `current` were laid out at a higher backing scale (a 2x
    /// display since switched to 1x, say).
    static func legacyCanvas(holding frames: [PixelRect], current: PixelSize) -> PixelSize {
        for factor in 1...4 {
            let canvas = PixelSize(width: current.width * factor, height: current.height * factor)
            let fits = frames.allSatisfy { $0.maxX <= Double(canvas.width) + 0.5 && $0.maxY <= Double(canvas.height) + 0.5 }
            if fits { return canvas }
        }
        return current
    }

    /// Video sources from the back of the stack to the front. Ties keep their saved order.
    public var orderedVideoSources: [VideoSource] {
        videoSources.enumerated()
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map(\.element)
    }

    // MARK: Editing

    /// Adds a source on top of the stack.
    public mutating func add(_ source: VideoSource) {
        var source = source
        source.zIndex = (videoSources.map(\.zIndex).max() ?? -1) + 1
        videoSources.append(source)
    }

    public mutating func removeVideoSource(_ id: UUID) {
        videoSources.removeAll { $0.id == id }
        audioSources.removeAll { source in
            if case .browser(let videoID) = source.kind { return videoID == id }
            return false
        }
        normalizeStackOrder()
    }

    public mutating func add(_ source: AudioSource) {
        audioSources.append(source)
    }

    public mutating func removeAudioSource(_ id: UUID) {
        audioSources.removeAll { $0.id == id }
    }

    public mutating func setVolume(_ volume: Double, forAudioSource id: UUID) {
        guard let index = audioSources.firstIndex(where: { $0.id == id }) else { return }
        audioSources[index].volume = AudioSource.clampVolume(volume)
    }

    public mutating func bringToFront(_ id: UUID) {
        move(id) { order, index in order.append(order.remove(at: index)) }
    }

    public mutating func sendToBack(_ id: UUID) {
        move(id) { order, index in order.insert(order.remove(at: index), at: 0) }
    }

    public mutating func moveForward(_ id: UUID) {
        move(id) { order, index in
            guard index < order.count - 1 else { return }
            order.swapAt(index, index + 1)
        }
    }

    public mutating func moveBackward(_ id: UUID) {
        move(id) { order, index in
            guard index > 0 else { return }
            order.swapAt(index, index - 1)
        }
    }

    /// Rewrites `zIndex` as 0, 1, 2, … in the current stack order.
    public mutating func normalizeStackOrder() {
        let order = orderedVideoSources.map(\.id)
        for (z, id) in order.enumerated() {
            if let i = videoSources.firstIndex(where: { $0.id == id }) { videoSources[i].zIndex = z }
        }
    }

    /// Pulls every value into its legal range. None of it depends on the canvas's pixel size, so a change of
    /// display, resolution or backing scale never alters a saved layout. A layout still holding version-1 pixels is
    /// left alone until it's converted.
    public mutating func sanitize() {
        guard !holdsLegacyPixels else { return }
        for i in videoSources.indices {
            videoSources[i].frame = videoSources[i].frame.clamped()
            videoSources[i].crop = videoSources[i].crop.clamped()
            let opacity = videoSources[i].opacity
            videoSources[i].opacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
            let radius = videoSources[i].cornerRadius
            videoSources[i].cornerRadius = radius.isFinite ? max(0, radius) : 0
            let width = videoSources[i].border.width
            videoSources[i].border.width = width.isFinite ? max(0, width) : 0
        }
        for i in audioSources.indices { audioSources[i].volume = AudioSource.clampVolume(audioSources[i].volume) }
        minecraftAudioVolume = AudioSource.clampVolume(minecraftAudioVolume)
        webPageAudioVolume = AudioSource.clampVolume(webPageAudioVolume)
    }

    private mutating func move(_ id: UUID, _ change: (inout [UUID], Int) -> Void) {
        var order = orderedVideoSources.map(\.id)
        guard let index = order.firstIndex(of: id) else { return }
        change(&order, index)
        for (z, sourceID) in order.enumerated() {
            if let i = videoSources.firstIndex(where: { $0.id == sourceID }) { videoSources[i].zIndex = z }
        }
    }
}
