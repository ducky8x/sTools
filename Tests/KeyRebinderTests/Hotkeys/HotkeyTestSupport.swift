import Foundation
@testable import KeyRebinder
import STPlatform

/// Stands in for macOS's hotkey registration: remembers what is registered and refuses the combinations in
/// `refused`. Never registers a real hotkey.
@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistering {
    struct Refusal: Error {}

    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var registered: [UUID: HotkeyCombo] = [:]
    var refused: Set<HotkeyCombo> = []

    func register(_ combo: HotkeyCombo, id: UUID) throws {
        if refused.contains(combo) { throw Refusal() }
        registered[id] = combo
    }

    func unregister(id: UUID) {
        registered[id] = nil
    }
}

/// Keyboards, keybinds, combinations and rebinds for the hotkey tests.
enum HotkeyFixtures {
    /// An ANSI laptop keyboard (F1–F12, no keypad) and mouse buttons 1–8.
    static let laptop = physicalKeys(.ansi, .laptop)
    /// An ANSI full-size keyboard (F13–F19 and a keypad drawn) and mouse buttons 1–8.
    static let fullSize = physicalKeys(.ansi, .fullSize)

    static func physicalKeys(_ shape: KeyboardShape, _ formFactor: KeyboardFormFactor) -> [KarabinerEvent] {
        KeyboardLayout(shape: shape, formFactor: formFactor).keys.map(\.event) + MouseLayout.buttons.map(\.event)
    }

    /// The 1.16.1 `options.txt` fixture: Sneak on Left Shift, Sprint on Left Control, C saves the hotbar.
    static var options1161Text: String { text("rules-options-1.16.1.txt") }
    static var options1161: [MinecraftKeybind] { MinecraftKeybinds.parse(optionsText: options1161Text) }

    static func keybinds(_ optionsText: String) -> [MinecraftKeybind] {
        MinecraftKeybinds.parse(optionsText: optionsText)
    }

    static func text(_ name: String) -> String {
        let url = FixtureLoader.directory.appending(path: name)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            fatalError("missing fixture \(name)")
        }
        return text
    }

    /// A combination on the key Karabiner calls `code` ("f18", "keypad_1", "return_or_enter").
    static func combo(_ code: String, _ modifiers: HotkeyCombo.Modifiers = []) -> HotkeyCombo {
        guard let virtualKey = KeyTable.shared.virtualKeyCode(for: .key(code)) else { fatalError("\(code) has no virtual key") }
        return HotkeyCombo(keyCode: UInt16(virtualKey), modifiers: modifiers)
    }

    static func hotkey(
        _ code: String, _ modifiers: HotkeyCombo.Modifiers = [], _ actions: [HotkeyAction] = [.toggle(.crosshair)]
    ) -> HotkeyBinding {
        HotkeyBinding(combo: combo(code, modifiers), actions: actions)
    }

    /// What each key of profile "P" sends, with these key-to-key rebinds, raw Simple Modifications and rules.
    static func bindings(
        _ pairs: [(String, String)] = [], simple: [String] = [], rules: [String] = []
    ) -> [KarabinerEvent: EffectiveBinding] {
        EffectiveMapping.bindings(in: config(pairs, simple: simple, rules: rules), profile: "P")
    }

    static func config(_ pairs: [(String, String)] = [], simple: [String] = [], rules: [String] = []) -> JSONValue {
        let entries = pairs.map { TestConfig.pair($0.0, $0.1) } + simple
        return TestConfig.profile(
            simple: entries.isEmpty ? nil : "[\(entries.joined(separator: ", "))]",
            rules: rules.isEmpty ? nil : "[\(rules.joined(separator: ", "))]")
    }

    /// A Simple Modification from a mouse button.
    static func buttonPair(_ button: String, _ to: String) -> String {
        "{ \"from\": { \"pointing_button\": \"\(button)\" }, \"to\": [{ \"key_code\": \"\(to)\" }] }"
    }

    /// A Simple Modification to a raw `to` list.
    static func toList(_ from: String, _ to: String) -> String {
        "{ \"from\": { \"key_code\": \"\(from)\" }, \"to\": \(to) }"
    }

    /// A rule that sends `alone` when `from` is tapped and `held` while it is held.
    static func tapHoldRule(_ from: String, held: String, alone: String) -> String {
        TestConfig.rule("Tap/hold", """
            { "type": "basic", "from": { "key_code": "\(from)" }, "to": [{ "key_code": "\(held)" }],
              "to_if_alone": [{ "key_code": "\(alone)" }] }
            """)
    }
}

/// Waits, a little at a time, until `condition` holds (the controller follows the hotkey list one main-actor turn
/// later). False when it still doesn't after `timeout`.
@MainActor
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
