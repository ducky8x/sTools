import Foundation
import STDesign
import STPlatform

/// Settings ▸ Appearance, persisted as `appearance.json`.
struct AppearanceSettings: SettingsDocument {
    static let name = "appearance"
    static let version = 1
    static let defaultValue = AppearanceSettings()

    var soundsEnabled = true
    /// 0...1.
    var soundVolume = 0.7
    var motionMode = STMotionMode.full
    /// 0.9...1.3.
    var textScale = 1.0
    var accentHex = STPalette.gold

    init() {}

    private enum CodingKeys: String, CodingKey {
        case soundsEnabled, soundVolume, motionMode, textScale, accentHex
    }

    /// Every key is optional on disk, so a file from an older or hand-edited build still loads.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppearanceSettings()
        soundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? defaults.soundsEnabled
        soundVolume = try container.decodeIfPresent(Double.self, forKey: .soundVolume) ?? defaults.soundVolume
        motionMode = try container.decodeIfPresent(STMotionMode.self, forKey: .motionMode) ?? defaults.motionMode
        textScale = try container.decodeIfPresent(Double.self, forKey: .textScale) ?? defaults.textScale
        accentHex = try container.decodeIfPresent(String.self, forKey: .accentHex) ?? defaults.accentHex
    }

    /// Pushes these values into the live theme.
    @MainActor
    func apply(to theme: STTheme) {
        theme.soundsEnabled = soundsEnabled
        theme.soundVolume = soundVolume
        theme.motionMode = motionMode
        theme.textScale = textScale
        theme.accentHex = accentHex
    }

    /// The values as the theme holds them after clamping and accent sanitizing, so what is saved is what is shown.
    @MainActor
    init(theme: STTheme) {
        soundsEnabled = theme.soundsEnabled
        soundVolume = theme.soundVolume
        motionMode = theme.motionMode
        textScale = theme.textScale
        accentHex = theme.accentHex
    }
}

/// The percent text the Appearance sliders show and accept.
enum PercentFormat {
    /// "70%" for 70.
    static func text(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    /// Reads "70", "70%" or "70 %"; `nil` when there is no number.
    static func parse(_ text: String) -> Double? {
        STSlider.defaultParse(text)
    }
}
