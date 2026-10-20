/// Translation of Minecraft's key names (and the numeric codes older versions wrote) into Karabiner-Elements events.
///
/// Minecraft 1.16.1 writes GLFW names such as `key.keyboard.left.shift` and `key.mouse.4`.
/// Karabiner sits below the game, so the event to compare against is the one the game receives:
/// on a Mac, Minecraft's `left.alt` is the Option key and `left.win` is Command.
public enum MinecraftKeyNames {
    private static let keyboardPrefix = "key.keyboard."
    private static let mousePrefix = "key.mouse."

    /// Names after `key.keyboard.` that have no Karabiner key code (`unknown`, `world.1`, `world.2`, `f25`)
    /// are deliberately absent.
    private static let keyboard: [String: String] = {
        var table: [String: String] = [
            "space": "spacebar", "apostrophe": "quote", "comma": "comma", "minus": "hyphen", "period": "period",
            "slash": "slash", "semicolon": "semicolon", "equal": "equal_sign", "left.bracket": "open_bracket",
            "backslash": "backslash", "right.bracket": "close_bracket", "grave.accent": "grave_accent_and_tilde",
            "escape": "escape", "enter": "return_or_enter", "tab": "tab", "backspace": "delete_or_backspace",
            "insert": "insert", "delete": "delete_forward", "right": "right_arrow", "left": "left_arrow",
            "down": "down_arrow", "up": "up_arrow", "page.up": "page_up", "page.down": "page_down",
            "home": "home", "end": "end", "caps.lock": "caps_lock", "scroll.lock": "scroll_lock",
            "num.lock": "keypad_num_lock", "print.screen": "print_screen", "pause": "pause",
            "keypad.decimal": "keypad_period", "keypad.divide": "keypad_slash", "keypad.multiply": "keypad_asterisk",
            "keypad.subtract": "keypad_hyphen", "keypad.add": "keypad_plus", "keypad.enter": "keypad_enter",
            "keypad.equal": "keypad_equal_sign",
            "left.shift": "left_shift", "left.control": "left_control", "left.alt": "left_option",
            "left.win": "left_command", "right.shift": "right_shift", "right.control": "right_control",
            "right.alt": "right_option", "right.win": "right_command", "menu": "application",
        ]
        for digit in 0...9 {
            table[String(digit)] = String(digit)
            table["keypad.\(digit)"] = "keypad_\(digit)"
        }
        for letter in "abcdefghijklmnopqrstuvwxyz" { table[String(letter)] = String(letter) }
        for number in 1...24 { table["f\(number)"] = "f\(number)" }
        return table
    }()

    /// Maps `key.keyboard.*` and `key.mouse.*` names. `nil` for unbound (`key.keyboard.unknown`), keys
    /// Karabiner cannot express, and anything unrecognized.
    public static func event(forName name: String) -> KarabinerEvent? {
        if name.hasPrefix(keyboardPrefix) {
            return keyboard[String(name.dropFirst(keyboardPrefix.count))].map(KarabinerEvent.key)
        }
        if name.hasPrefix(mousePrefix) {
            switch name.dropFirst(mousePrefix.count) {
            case "left": return .pointing("button1")
            case "right": return .pointing("button2")
            case "middle": return .pointing("button3")
            case let number:
                guard let value = Int(number), String(value) == number, (4...8).contains(value) else { return nil }
                return .pointing("button\(value)")
            }
        }
        return nil
    }

    /// LWJGL 2 keyboard codes, written by Minecraft 1.12 and older.
    private static let legacyKeyboard: [Int: String] = {
        var table: [Int: String] = [
            1: "escape", 12: "hyphen", 13: "equal_sign", 14: "delete_or_backspace", 15: "tab",
            26: "open_bracket", 27: "close_bracket", 28: "return_or_enter", 29: "left_control",
            39: "semicolon", 40: "quote", 41: "grave_accent_and_tilde", 42: "left_shift", 43: "backslash",
            51: "comma", 52: "period", 53: "slash", 54: "right_shift", 55: "keypad_asterisk", 56: "left_option",
            57: "spacebar", 58: "caps_lock", 69: "keypad_num_lock", 70: "scroll_lock",
            74: "keypad_hyphen", 78: "keypad_plus", 83: "keypad_period", 141: "keypad_equal_sign",
            156: "keypad_enter", 157: "right_control", 181: "keypad_slash", 183: "print_screen",
            184: "right_option", 197: "pause", 199: "home", 200: "up_arrow", 201: "page_up", 203: "left_arrow",
            205: "right_arrow", 207: "end", 208: "down_arrow", 209: "page_down", 210: "insert",
            211: "delete_forward", 219: "left_command", 220: "right_command", 221: "application",
        ]
        for (offset, digit) in "1234567890".enumerated() { table[2 + offset] = String(digit) }
        for (offset, letter) in "qwertyuiop".enumerated() { table[16 + offset] = String(letter) }
        for (offset, letter) in "asdfghjkl".enumerated() { table[30 + offset] = String(letter) }
        for (offset, letter) in "zxcvbnm".enumerated() { table[44 + offset] = String(letter) }
        for number in 1...10 { table[58 + number] = "f\(number)" }
        table[87] = "f11"
        table[88] = "f12"
        for (offset, number) in (13...15).enumerated() { table[100 + offset] = "f\(number)" }
        for (offset, digit) in [7, 8, 9].enumerated() { table[71 + offset] = "keypad_\(digit)" }
        for (offset, digit) in [4, 5, 6].enumerated() { table[75 + offset] = "keypad_\(digit)" }
        for (offset, digit) in [1, 2, 3].enumerated() { table[79 + offset] = "keypad_\(digit)" }
        table[82] = "keypad_0"
        return table
    }()

    /// Maps the numeric form of Minecraft 1.12 and older: mouse buttons are `-100 + index` (-100 left,
    /// -99 right, -98 middle, -97 button 4...), keyboard keys are LWJGL 2 codes, and 0 means unbound.
    public static func event(forLegacyCode code: Int) -> KarabinerEvent? {
        if (-100...(-93)).contains(code) { return .pointing("button\(code + 101)") }
        return legacyKeyboard[code].map(KarabinerEvent.key)
    }
}
