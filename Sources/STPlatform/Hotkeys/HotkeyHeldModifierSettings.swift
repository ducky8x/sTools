import Foundation

/// Home ▸ Hotkeys ▸ Advanced ▸ Also fire while holding Shift or Control (spec 6.1): on by default, so each hotkey also
/// works while someone sneaks or sprints in Minecraft.
///
/// Stored as its own document, `hotkeyHeldModifiers.json`, apart from `hotkeys.json`: the saved hotkey list is never
/// touched by the option or by what it makes `HotkeyCenter` register, and nothing is written until the option is
/// changed. A missing or wrongly typed value reads as on.
public struct HotkeyHeldModifierSettings: SettingsDocument {
    public static let name = "hotkeyHeldModifiers"
    public static let version = 1
    public static let defaultValue = HotkeyHeldModifierSettings()

    /// Whether each hotkey also fires with Shift, Control or both held, as well as exactly as set.
    public var alsoFiresWithShiftOrControl: Bool

    public init(alsoFiresWithShiftOrControl: Bool = true) {
        self.alsoFiresWithShiftOrControl = alsoFiresWithShiftOrControl
    }

    private enum CodingKeys: String, CodingKey { case alsoFiresWithShiftOrControl }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alsoFiresWithShiftOrControl = (try? container.decodeIfPresent(Bool.self, forKey: .alsoFiresWithShiftOrControl)) ?? true
    }
}
