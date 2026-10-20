import Foundation
import STPlatform

/// The Key Rebinder's settings (spec 5.5.9). Rebinds themselves live in Karabiner's own file, never here.
public struct KeyRebinderSettings: SettingsDocument {
    public static let name = "keyRebinder"
    public static let version = 1
    public static var defaultValue: KeyRebinderSettings { KeyRebinderSettings() }

    public static let backupsKeptChoices = [10, 20, 50]
    public static let backupsKeptRange = 1...500

    /// Both stay nil until the user answers the first-use layout question.
    public var keyboardShape: KeyboardShape?
    public var formFactor: KeyboardFormFactor?
    /// The one device rebinds apply to; nil is All devices.
    public var scopeDevice: DeviceIdentifiers?
    public var showsMinecraftKeybinds = true
    /// A chosen `options.txt`; nil finds it through the running Minecraft.
    public var customOptionsFilePath: String?
    /// The `options.txt` found the last time Minecraft was running, so its keybinds still show after it quits.
    public var lastFoundOptionsFilePath: String?
    public var checkerEnabled = true
    public var checkerIncludesSpeedrunRules = true
    public var showsHoverArcs = true
    public var backupsKept = 20

    public init() {}

    /// The keyboard to draw, once chosen.
    public var layout: KeyboardLayout? {
        guard let keyboardShape, let formFactor else { return nil }
        return KeyboardLayout(shape: keyboardShape, formFactor: formFactor)
    }

    public var scope: RebindScope { scopeDevice.map(RebindScope.device) ?? .allDevices }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = KeyRebinderSettings()
        keyboardShape = container.lossy(KeyboardShape.self, .keyboardShape)
        formFactor = container.lossy(KeyboardFormFactor.self, .formFactor)
        scopeDevice = container.lossy(DeviceIdentifiers.self, .scopeDevice)
        showsMinecraftKeybinds = container.lossy(Bool.self, .showsMinecraftKeybinds) ?? defaults.showsMinecraftKeybinds
        customOptionsFilePath = container.lossy(String.self, .customOptionsFilePath).flatMap { $0.isEmpty ? nil : $0 }
        lastFoundOptionsFilePath = container.lossy(String.self, .lastFoundOptionsFilePath).flatMap { $0.isEmpty ? nil : $0 }
        checkerEnabled = container.lossy(Bool.self, .checkerEnabled) ?? defaults.checkerEnabled
        checkerIncludesSpeedrunRules = container.lossy(Bool.self, .checkerIncludesSpeedrunRules) ?? defaults.checkerIncludesSpeedrunRules
        showsHoverArcs = container.lossy(Bool.self, .showsHoverArcs) ?? defaults.showsHoverArcs
        let kept = container.lossy(Int.self, .backupsKept) ?? defaults.backupsKept
        backupsKept = min(max(kept, Self.backupsKeptRange.lowerBound), Self.backupsKeptRange.upperBound)
    }
}

extension KeyedDecodingContainer {
    fileprivate func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
