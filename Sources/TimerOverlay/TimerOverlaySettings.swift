import Foundation
import STDesign
import STPlatform

/// Timer Overlay's persisted settings (spec 5.6.7): every row of the table, each stored as its own value.
///
/// The defaults are the owner's saved setup (Timer round A3) plus the round's answers. Values read from disk
/// are decoded field by field: a missing or unusable field falls back to its default, and `clamped()` pulls
/// every number back into its range, so a hand-edited or damaged file can never produce an unusable timer.
///
/// The color overrides are optional: nil means "as the look sets it", so the look's own colors still apply
/// until the owner picks one.
public struct TimerOverlaySettings: SettingsDocument {
    public static let name = "timerOverlay"
    public static let version = 1
    public static var defaultValue: TimerOverlaySettings { TimerOverlaySettings() }

    // MARK: - Choices

    /// The overlay's looks (Timer round D1, D1a), each fully customizable afterwards.
    public enum Look: String, Codable, CaseIterable, Sendable {
        /// A `background` plate at 85%, a `rule` hairline edge and 12 pt corners, the NBB Overlay's family.
        case plate
        /// No plate: digits with a thin dark outline.
        case digitsOnly
        /// A capsule plate with tighter padding, in the plate's colors.
        case compactPill
    }

    public enum ProgressStyle: String, Codable, CaseIterable, Sendable {
        /// Only the time.
        case off
        /// A bar under the digits.
        case bar
        /// A ring around the digits.
        case ring
    }

    /// The digits' color as zero gets close (Timer round C3).
    public enum NearZero: String, Codable, CaseIterable, Sendable {
        /// The look stays the same until zero.
        case off
        /// `gold` from `nearZeroGoldSeconds` left.
        case gold
        /// `gold` from `nearZeroGoldSeconds` left, then `danger` from `nearZeroDangerSeconds` left.
        case goldThenDanger
    }

    /// How the time left is written (see `ClockFormat`).
    public enum TimeFormat: String, Codable, CaseIterable, Sendable {
        /// `MM:SS`, and `H:MM:SS` from one hour.
        case minutesAndSeconds
        /// `M:SS`, and `H:MM:SS` from one hour.
        case shortMinutes
        /// The whole seconds left, such as `150`.
        case secondsOnly
    }

    /// How the overlay comes and goes (Timer round F1).
    public enum PopUpMotion: String, Codable, CaseIterable, Sendable {
        /// Scales up from about 0.9 while fading in, and leaves the same way reversed.
        case springPop
        case fade
        /// Slides in from the nearest display edge.
        case slide
        /// No motion at all.
        case instant
    }

    /// What the overlay shows from zero until it leaves (Timer round F2).
    public enum AtZero: String, Codable, CaseIterable, Sendable {
        /// Holds `00:00`.
        case holdZero
        /// Shows `atZeroWord`.
        case word
        /// Counts up the time since zero, such as `+0:07`.
        case overtime
    }

    /// What the overlay does while the alarm rings (Timer round F3).
    public enum WhileRinging: String, Codable, CaseIterable, Sendable {
        /// One soft pulse as each ring starts.
        case pulsePerRing
        /// The time's-up look, holding still.
        case timesUpLookOnly
        /// A few quick flashes, at most 3 a second.
        case quickFlashes
    }

    /// When the overlay leaves after zero (Timer round F4).
    public enum Leave: String, Codable, CaseIterable, Sendable {
        /// `leaveAfterLastRingSeconds` after the alarm's last ring ends.
        case afterLastRing
        /// `leaveAfterZeroSeconds` after zero; an alarm that runs longer stops with the overlay.
        case afterZero
    }

    /// What a paused overlay does (Timer round C2).
    public enum WhilePaused: String, Codable, CaseIterable, Sendable {
        /// Shows the frozen time marked Paused, then hides after 3 s; it comes back on resume.
        case hideAfterDelay
        case stayUp
        case hideAtOnce
    }

    /// What a Start-timer press does while a countdown runs or is paused (spec 5.6.2, Timer round B4).
    public enum PressWhileCounting: String, Codable, CaseIterable, Sendable {
        /// Restarts from the full duration.
        case restart
        /// Cancels and hides.
        case cancel
        /// Pauses a running countdown and resumes a paused one.
        case pauseOrResume
        case ignore
    }

    /// What a Start-timer press does while the alarm rings or the overlay lingers after it (Timer round B5).
    public enum PressWhileRinging: String, Codable, CaseIterable, Sendable {
        /// Stops the alarm and starts a new countdown.
        case newCountdown
        case silenceAndHide
        case ignore
    }

    /// The key gesture that cancels a countdown (Timer round B6).
    public enum CancelGesture: String, Codable, CaseIterable, Sendable {
        /// A second press within 0.4 s cancels; the first press has already acted.
        case doublePress
        /// Holding the key 1 s cancels; the press has already acted.
        case hold
        case off
    }

    /// A sound before zero (Timer round G2).
    public enum BeforeZero: String, Codable, CaseIterable, Sendable {
        case nothing
        /// sTools' chime at `chimeAtSeconds` left.
        case chime
        /// A soft tick each second for the last 5 s.
        case ticks
    }

    public enum DisplayChoice: String, Codable, CaseIterable, Sendable {
        /// Minecraft's display, or the main display while Minecraft isn't running.
        case followMinecraft
        /// `specificDisplayID`.
        case specific
    }

    /// The rule note on the Timer page (Timer round I1, spec 5.6.8).
    public enum RuleNote: String, Codable, CaseIterable, Sendable {
        case off
        /// One advisory line.
        case line
        /// The line, plus a notice the first time the tool is turned on, until it's dismissed.
        case lineAndNotice
    }

    public enum Corner: String, Codable, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Minecraft's GUI scale, for the rule guides (spec 5.6.5). Stored as Minecraft's own number: 0 is Auto.
    public enum GUIScale: Hashable, Sendable, Codable {
        /// Minecraft's automatic scale for the window's size.
        case auto
        /// A fixed scale, 1 or more.
        case fixed(Int)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)
            switch value {
            case 0: self = .auto
            case 1...: self = .fixed(value)
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "A GUI scale is 0 (Auto) or more.")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .auto: try container.encode(0)
            case .fixed(let scale): try container.encode(scale)
            }
        }
    }

    /// A duration chip on the page. The list is the owner's to edit: add, remove, rename.
    public struct Preset: Codable, Hashable, Sendable {
        public var title: String
        public var seconds: Int

        public init(title: String, seconds: Int) {
            self.title = title
            self.seconds = seconds
        }
    }

    // MARK: - Ranges

    /// 1 s to 99:59:59.
    public static let durationRange = 1...359_999
    public static let digitSizeRange = 28...140
    /// Offsets are clamped to the display when the overlay is placed; this bound only keeps stored values sane.
    public static let offsetLimit = 16_384
    public static let plateOpacityRange = 60...100
    public static let edgeWidthRange = 0.0...6.0
    public static let cornerRadiusRange = 0.0...100.0
    /// The near-zero colors' and the chime's times, in seconds left.
    public static let secondsLeftRange = 1...359_999
    public static let leaveAfterLastRingRange = 0.0...60.0
    public static let leaveAfterZeroRange = 1.0...120.0
    public static let volumeRange = 0.0...1.0
    public static let ringsRange = 1...10
    public static let guiScaleRange = 1...16

    public static let defaultFontFamily = "Source Serif 4"
    public static let defaultSoundID = "macOS:Ping"

    /// The page's duration chips (spec 5.6.3): 30s · 1m · 2:30 · 5m · 10m · 25m · 1h.
    public static let defaultPresets: [Preset] = [
        Preset(title: "30s", seconds: 30), Preset(title: "1m", seconds: 60), Preset(title: "2:30", seconds: 150),
        Preset(title: "5m", seconds: 300), Preset(title: "10m", seconds: 600), Preset(title: "25m", seconds: 1500),
        Preset(title: "1h", seconds: 3600),
    ]

    // MARK: - The countdown

    /// What the key and Start count down from. A change applies to the next run, never to one in progress.
    public var durationSeconds = 150
    public var presets = TimerOverlaySettings.defaultPresets

    // MARK: - The overlay

    public var look: Look = .plate
    /// The digits' size in points.
    public var digitSize = 40
    /// Points right (+) or left (-) of the display's center to the plate's center. The default is the
    /// owner's saved spot (Timer round E2, E2a).
    public var offsetX = 453
    /// Points down (+) or up (-) from the display's center to the plate's center, as for the NBB Overlay.
    public var offsetY = -459
    /// A font family name. Source Serif 4, New York, SF Pro and Bodoni Moda are offered by name; any
    /// installed family works, and a missing one falls back to Source Serif 4 when drawn.
    public var fontFamily = TimerOverlaySettings.defaultFontFamily

    /// `#RRGGBB`; nil is the look's own.
    public var plateColorHex: String?
    /// nil is the look's own (85%).
    public var plateOpacityPercent: Int?
    /// `#RRGGBB`; nil is the look's `rule` hairline.
    public var edgeColorHex: String?
    /// Points; 0 draws no edge, nil is the look's hairline.
    public var edgeWidth: Double?
    /// Points; nil is the look's own (12 pt, or round ends for the pill).
    public var cornerRadius: Double?
    /// `#RRGGBB`; nil is the look's own.
    public var digitColorHex: String?
    /// `#RRGGBB` for the time's-up look; nil is the look's own.
    public var timesUpPlateColorHex: String?
    public var timesUpDigitColorHex: String?

    public var showsLabel = false
    public var labelText = "Fire res"
    public var progress: ProgressStyle = .off
    public var nearZero: NearZero = .off
    public var nearZeroGoldSeconds = 30
    public var nearZeroDangerSeconds = 10
    public var timeFormat: TimeFormat = .minutesAndSeconds
    /// Tenths of a second in the last 10 s.
    public var showsTenths = false

    public var popUpMotion: PopUpMotion = .springPop
    public var atZero: AtZero = .holdZero
    public var atZeroWord = "Time"
    public var whileRinging: WhileRinging = .pulsePerRing
    public var leave: Leave = .afterLastRing
    public var leaveAfterLastRingSeconds: Double = 2
    public var leaveAfterZeroSeconds: Double = 5
    public var whilePaused: WhilePaused = .hideAfterDelay

    // MARK: - The key

    public var pressWhileCounting: PressWhileCounting = .restart
    public var pressWhileRinging: PressWhileRinging = .newCountdown
    public var cancelGesture: CancelGesture = .doublePress

    // MARK: - The alarm

    public var beforeZero: BeforeZero = .nothing
    public var chimeAtSeconds = 30
    /// `macOS:<name>`, `sTools:<name>` or `file:<name>` (a file in `Sounds/` in the settings folder).
    public var soundID = TimerOverlaySettings.defaultSoundID
    /// 0...1, the alarm's own volume. sTools' Sounds setting and macOS's interface sounds don't affect it.
    public var volume = 0.8
    public var rings = 3
    /// Whether the overlay is in sTools' recordings and screen captures. Turning it off hides an aid from
    /// the run's video (A.12.3), so the page warns first.
    public var showsInRecordings = true
    /// Whether the alarm is in sTools' recordings, on its own *Timer alarm* track.
    public var alarmInRecordings = false

    // MARK: - Where it shows

    /// An independent restriction, the same shape as the Crosshair's: hidden while Minecraft isn't in front.
    public var visibleOnlyWhileMinecraftFocused = false
    public var pausesWhileMinecraftNotFocused = false
    public var displayChoice: DisplayChoice = .followMinecraft
    public var specificDisplayID: UInt32?
    public var snappingEnabled = true

    // MARK: - Placement and the page

    public var showsRuleGuides = true
    public var guiScale: GUIScale = .fixed(3)
    public var speedRunIGTCorner: Corner = .topRight
    public var ruleNote: RuleNote = .off
    /// Whether the owner dismissed the rule notice (`RuleNote.lineAndNotice`).
    public var ruleNoticeDismissed = false
    /// A badge with the time left, and Start / Pause / Cancel in the Dock menu.
    public var showsDockCountdown = false
    /// When on, the overlay stays up and can be dragged into place.
    public var placementModeEnabled = false

    public init() {}

    /// This value with every field inside its range, colors normalized and unusable text replaced.
    public func clamped() -> TimerOverlaySettings {
        var result = self
        result.durationSeconds = durationSeconds.clamped(to: Self.durationRange)
        result.presets = presets.map { Preset(title: $0.title, seconds: $0.seconds.clamped(to: Self.durationRange)) }
        result.digitSize = digitSize.clamped(to: Self.digitSizeRange)
        result.offsetX = offsetX.clamped(to: -Self.offsetLimit...Self.offsetLimit)
        result.offsetY = offsetY.clamped(to: -Self.offsetLimit...Self.offsetLimit)
        if fontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.fontFamily = Self.defaultFontFamily }

        result.plateColorHex = plateColorHex.flatMap(STColorWellHex.normalized)
        result.plateOpacityPercent = plateOpacityPercent.map { $0.clamped(to: Self.plateOpacityRange) }
        result.edgeColorHex = edgeColorHex.flatMap(STColorWellHex.normalized)
        result.edgeWidth = edgeWidth.flatMap { $0.isFinite ? $0.clamped(to: Self.edgeWidthRange) : nil }
        result.cornerRadius = cornerRadius.flatMap { $0.isFinite ? $0.clamped(to: Self.cornerRadiusRange) : nil }
        result.digitColorHex = digitColorHex.flatMap(STColorWellHex.normalized)
        result.timesUpPlateColorHex = timesUpPlateColorHex.flatMap(STColorWellHex.normalized)
        result.timesUpDigitColorHex = timesUpDigitColorHex.flatMap(STColorWellHex.normalized)

        result.nearZeroGoldSeconds = nearZeroGoldSeconds.clamped(to: Self.secondsLeftRange)
        result.nearZeroDangerSeconds = nearZeroDangerSeconds.clamped(to: Self.secondsLeftRange)
        result.chimeAtSeconds = chimeAtSeconds.clamped(to: Self.secondsLeftRange)
        let defaults = TimerOverlaySettings()
        result.leaveAfterLastRingSeconds = leaveAfterLastRingSeconds.finiteOr(defaults.leaveAfterLastRingSeconds)
            .clamped(to: Self.leaveAfterLastRingRange)
        result.leaveAfterZeroSeconds = leaveAfterZeroSeconds.finiteOr(defaults.leaveAfterZeroSeconds)
            .clamped(to: Self.leaveAfterZeroRange)
        result.volume = volume.finiteOr(defaults.volume).clamped(to: Self.volumeRange)
        result.rings = rings.clamped(to: Self.ringsRange)
        if !Self.isUsableSoundID(soundID) { result.soundID = Self.defaultSoundID }
        if case .fixed(let scale) = guiScale { result.guiScale = .fixed(scale.clamped(to: Self.guiScaleRange)) }
        return result
    }

    /// Not blank, and a `file:` ID names a plain file inside `Sounds/`, never a path.
    static func isUsableSoundID(_ id: String) -> Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard id.hasPrefix("file:") else { return true }
        let name = id.dropFirst("file:".count)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TimerOverlaySettings()
        durationSeconds = container.lossy(Int.self, .durationSeconds) ?? defaults.durationSeconds
        presets = container.lossy([LossyPreset].self, .presets).map { $0.compactMap(\.preset) } ?? defaults.presets
        look = container.lossy(Look.self, .look) ?? defaults.look
        digitSize = container.lossy(Int.self, .digitSize) ?? defaults.digitSize
        offsetX = container.lossy(Int.self, .offsetX) ?? defaults.offsetX
        offsetY = container.lossy(Int.self, .offsetY) ?? defaults.offsetY
        fontFamily = container.lossy(String.self, .fontFamily) ?? defaults.fontFamily
        plateColorHex = container.lossy(String.self, .plateColorHex)
        plateOpacityPercent = container.lossy(Int.self, .plateOpacityPercent)
        edgeColorHex = container.lossy(String.self, .edgeColorHex)
        edgeWidth = container.lossy(Double.self, .edgeWidth)
        cornerRadius = container.lossy(Double.self, .cornerRadius)
        digitColorHex = container.lossy(String.self, .digitColorHex)
        timesUpPlateColorHex = container.lossy(String.self, .timesUpPlateColorHex)
        timesUpDigitColorHex = container.lossy(String.self, .timesUpDigitColorHex)
        showsLabel = container.lossy(Bool.self, .showsLabel) ?? defaults.showsLabel
        labelText = container.lossy(String.self, .labelText) ?? defaults.labelText
        progress = container.lossy(ProgressStyle.self, .progress) ?? defaults.progress
        nearZero = container.lossy(NearZero.self, .nearZero) ?? defaults.nearZero
        nearZeroGoldSeconds = container.lossy(Int.self, .nearZeroGoldSeconds) ?? defaults.nearZeroGoldSeconds
        nearZeroDangerSeconds = container.lossy(Int.self, .nearZeroDangerSeconds) ?? defaults.nearZeroDangerSeconds
        timeFormat = container.lossy(TimeFormat.self, .timeFormat) ?? defaults.timeFormat
        showsTenths = container.lossy(Bool.self, .showsTenths) ?? defaults.showsTenths
        popUpMotion = container.lossy(PopUpMotion.self, .popUpMotion) ?? defaults.popUpMotion
        atZero = container.lossy(AtZero.self, .atZero) ?? defaults.atZero
        atZeroWord = container.lossy(String.self, .atZeroWord) ?? defaults.atZeroWord
        whileRinging = container.lossy(WhileRinging.self, .whileRinging) ?? defaults.whileRinging
        leave = container.lossy(Leave.self, .leave) ?? defaults.leave
        leaveAfterLastRingSeconds = container.lossy(Double.self, .leaveAfterLastRingSeconds) ?? defaults.leaveAfterLastRingSeconds
        leaveAfterZeroSeconds = container.lossy(Double.self, .leaveAfterZeroSeconds) ?? defaults.leaveAfterZeroSeconds
        whilePaused = container.lossy(WhilePaused.self, .whilePaused) ?? defaults.whilePaused
        pressWhileCounting = container.lossy(PressWhileCounting.self, .pressWhileCounting) ?? defaults.pressWhileCounting
        pressWhileRinging = container.lossy(PressWhileRinging.self, .pressWhileRinging) ?? defaults.pressWhileRinging
        cancelGesture = container.lossy(CancelGesture.self, .cancelGesture) ?? defaults.cancelGesture
        beforeZero = container.lossy(BeforeZero.self, .beforeZero) ?? defaults.beforeZero
        chimeAtSeconds = container.lossy(Int.self, .chimeAtSeconds) ?? defaults.chimeAtSeconds
        soundID = container.lossy(String.self, .soundID) ?? defaults.soundID
        volume = container.lossy(Double.self, .volume) ?? defaults.volume
        rings = container.lossy(Int.self, .rings) ?? defaults.rings
        showsInRecordings = container.lossy(Bool.self, .showsInRecordings) ?? defaults.showsInRecordings
        alarmInRecordings = container.lossy(Bool.self, .alarmInRecordings) ?? defaults.alarmInRecordings
        visibleOnlyWhileMinecraftFocused = container.lossy(Bool.self, .visibleOnlyWhileMinecraftFocused)
            ?? defaults.visibleOnlyWhileMinecraftFocused
        pausesWhileMinecraftNotFocused = container.lossy(Bool.self, .pausesWhileMinecraftNotFocused)
            ?? defaults.pausesWhileMinecraftNotFocused
        displayChoice = container.lossy(DisplayChoice.self, .displayChoice) ?? defaults.displayChoice
        specificDisplayID = container.lossy(UInt32.self, .specificDisplayID)
        snappingEnabled = container.lossy(Bool.self, .snappingEnabled) ?? defaults.snappingEnabled
        showsRuleGuides = container.lossy(Bool.self, .showsRuleGuides) ?? defaults.showsRuleGuides
        guiScale = container.lossy(GUIScale.self, .guiScale) ?? defaults.guiScale
        speedRunIGTCorner = container.lossy(Corner.self, .speedRunIGTCorner) ?? defaults.speedRunIGTCorner
        ruleNote = container.lossy(RuleNote.self, .ruleNote) ?? defaults.ruleNote
        ruleNoticeDismissed = container.lossy(Bool.self, .ruleNoticeDismissed) ?? defaults.ruleNoticeDismissed
        showsDockCountdown = container.lossy(Bool.self, .showsDockCountdown) ?? defaults.showsDockCountdown
        placementModeEnabled = container.lossy(Bool.self, .placementModeEnabled) ?? defaults.placementModeEnabled
        self = clamped()
    }
}

/// One preset read from disk, or nil when it doesn't decode, so one bad entry drops only itself.
private struct LossyPreset: Decodable {
    let preset: TimerOverlaySettings.Preset?

    init(from decoder: any Decoder) throws {
        preset = try? TimerOverlaySettings.Preset(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// The decoded value, or nil when the key is missing, null or of the wrong type.
    fileprivate func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    fileprivate func finiteOr(_ fallback: Double) -> Double { isFinite ? self : fallback }
}
