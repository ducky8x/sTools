import SwiftUI
import Observation

/// Settings ▸ Appearance ▸ Reduce animations, as stored: off is `.full`, on is `.reduced`.
public enum STMotionMode: String, Codable, Sendable, CaseIterable {
    /// sTools' full motion (spec 3.4).
    case full
    /// No motion at all: every change happens at once.
    case reduced
}

/// The live appearance state every STDesign component reads from the environment.
@MainActor @Observable
public final class STTheme {
    /// Always a valid, uppercase `#RRGGBB` with at least 4.5:1 contrast against `background`; see `sanitizedAccent(_:)`.
    public var accentHex: String {
        get { storedAccentHex }
        set { storedAccentHex = Self.sanitizedAccent(newValue) }
    }

    /// Clamped to `textScaleRange`.
    public var textScale: Double {
        get { storedTextScale }
        set { storedTextScale = Self.clampedTextScale(newValue) }
    }

    /// Settings ▸ Appearance ▸ Reduce animations.
    public var motionMode: STMotionMode
    public var soundsEnabled: Bool

    /// Clamped to 0...1.
    public var soundVolume: Double {
        get { storedSoundVolume }
        set { storedSoundVolume = Self.clampedSoundVolume(newValue) }
    }

    /// Mirrors macOS's Reduce motion (Accessibility ▸ Display); the app target keeps it current.
    public var systemReduceMotion: Bool
    /// Mirrors the system "Increase Contrast" setting; the app target keeps it current.
    public var increaseContrast: Bool

    private var storedAccentHex: String
    private var storedTextScale: Double
    private var storedSoundVolume: Double

    public init(accentHex: String = STPalette.gold,
                textScale: Double = 1.0,
                motionMode: STMotionMode = .full,
                soundsEnabled: Bool = true,
                soundVolume: Double = 0.7,
                systemReduceMotion: Bool = false,
                increaseContrast: Bool = false) {
        self.storedAccentHex = Self.sanitizedAccent(accentHex)
        self.storedTextScale = Self.clampedTextScale(textScale)
        self.motionMode = motionMode
        self.soundsEnabled = soundsEnabled
        self.storedSoundVolume = Self.clampedSoundVolume(soundVolume)
        self.systemReduceMotion = systemReduceMotion
        self.increaseContrast = increaseContrast
    }

    public var accent: Color { Color(hex: accentHex) }
    /// Focus rings, switches and active marks: `goldStroke` for the default gold, otherwise the accent
    /// nudged toward the background, never below 3:1.
    public var accentStroke: Color { Color(hex: Self.strokeHex(forAccent: accentHex)) }
    /// Text and stroke colors that honor Increase Contrast (secondary/tertiary ink and stroke become `ink`).
    public var inkSecondary: Color { increaseContrast ? STColor.ink : STColor.inkSecondary }
    public var inkTertiary: Color { increaseContrast ? STColor.ink : STColor.inkTertiary }
    public var stroke: Color { increaseContrast ? STColor.ink : STColor.stroke }

    /// No motion at all (spec 3.4): Reduce animations is on, or macOS's Reduce motion is. Everything that moves reads
    /// this, through `STMotion`, `stAnimation` and `stMotionRoot`.
    public var reduceMotion: Bool { motionMode == .reduced || systemReduceMotion }

    /// Default for views outside an app that injects a real theme. Must first be read on the main thread
    /// (SwiftUI evaluates environment defaults there); reading it from a background thread traps.
    public nonisolated static let fallback: STTheme = MainActor.assumeIsolated { STTheme() }
}

extension STTheme {
    /// Settings ▸ Appearance ▸ Advanced allows 90-130%.
    nonisolated static let textScaleRange: ClosedRange<Double> = 0.9...1.3
    nonisolated static let defaultSoundVolume = 0.7

    /// Minimum contrast for accent text against `background`.
    nonisolated static let minimumAccentContrast = 4.5
    /// Minimum contrast for the accent stroke against every ground.
    nonisolated static let minimumStrokeContrast = 3.0

    nonisolated static func clampedTextScale(_ value: Double) -> Double {
        value.isFinite ? value.clamped(to: textScaleRange) : 1.0
    }

    nonisolated static func clampedSoundVolume(_ value: Double) -> Double {
        value.isNaN ? defaultSoundVolume : value.clamped(to: 0...1)
    }

    /// Turns any user-supplied accent into a usable one: invalid input becomes gold; a color below 4.5:1 against
    /// `background` is lightened toward white in 4% steps until it reaches 4.5:1. Result is uppercase `#RRGGBB`.
    nonisolated public static func sanitizedAccent(_ hex: String) -> String {
        guard let channels = STPalette.rgb(hex) else { return STPalette.gold }
        let original = STPalette.hex(red: channels.red, green: channels.green, blue: channels.blue)
        var candidate = original
        var step = 0
        while STPalette.contrastRatio(candidate, STPalette.background) < minimumAccentContrast, step < 25 {
            step += 1
            candidate = STPalette.mix(original, toward: "#FFFFFF", by: Double(step) * 0.04)
        }
        return candidate
    }

    /// The stroke color paired with an accent: `goldStroke` for the default gold, otherwise the accent mixed up to
    /// 12% toward the background, backing off until it holds 3:1 against `background`, `surface` and `raised`.
    nonisolated public static func strokeHex(forAccent hex: String) -> String {
        let accent = sanitizedAccent(hex)
        if accent == STPalette.gold { return STPalette.goldStroke }
        let grounds = [STPalette.background, STPalette.surface, STPalette.raised]
        for percent in stride(from: 12, through: 0, by: -2) {
            let candidate = STPalette.mix(accent, toward: STPalette.background, by: Double(percent) / 100)
            if grounds.allSatisfy({ STPalette.contrastRatio(candidate, $0) >= minimumStrokeContrast }) { return candidate }
        }
        return accent
    }
}

public extension EnvironmentValues {
    @Entry var stTheme: STTheme = STTheme.fallback
}
