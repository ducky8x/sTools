import CoreGraphics

/// The physical arrangement printed on the keyboard (spec 5.5.2).
public enum KeyboardShape: String, CaseIterable, Codable, Sendable {
    case ansi, iso, jis

    public var title: String {
        switch self {
        case .ansi: "ANSI"
        case .iso: "ISO"
        case .jis: "JIS"
        }
    }
}

public enum KeyboardFormFactor: String, CaseIterable, Codable, Sendable {
    /// A Mac laptop or compact keyboard: arrows tucked into the bottom row, no keypad.
    case laptop
    /// A full-size Mac keyboard: function keys to F19, navigation keys and a keypad.
    case fullSize

    public var title: String {
        switch self {
        case .laptop: "Laptop"
        case .fullSize: "Full-size"
        }
    }
}

/// One key or button drawn on the plate.
public struct KeyCap: Hashable, Sendable, Identifiable {
    /// The event this physical key sends before Karabiner changes anything.
    public let event: KarabinerEvent
    /// The US legend printed on the key.
    public let legend: String
    /// Where the key sits, in key units with the origin at the top left. One rect, or two for the tall Return
    /// of ISO and JIS keyboards (its upper and lower part).
    public let frames: [CGRect]

    public var id: KarabinerEvent { event }

    /// The smallest rect around every part of the key.
    public var bounds: CGRect { frames.dropFirst().reduce(frames[0]) { $0.union($1) } }

    public init(event: KarabinerEvent, legend: String, frames: [CGRect]) {
        precondition(!frames.isEmpty, "a key needs at least one frame")
        self.event = event
        self.legend = legend
        self.frames = frames
    }
}

/// The keys of one Mac keyboard, laid out in key units (1 = one letter key).
public struct KeyboardLayout: Equatable, Sendable {
    public let shape: KeyboardShape
    public let formFactor: KeyboardFormFactor
    public let keys: [KeyCap]
    /// The width and height every key fits inside.
    public let size: CGSize

    public init(shape: KeyboardShape, formFactor: KeyboardFormFactor) {
        self.shape = shape
        self.formFactor = formFactor
        var builder = LayoutBuilder()
        builder.addFunctionRow(formFactor)
        builder.addMainBlock(shape, formFactor)
        if formFactor == .fullSize {
            builder.addNavigationCluster()
            builder.addKeypad()
        }
        keys = builder.keys
        size = CGSize(width: formFactor == .fullSize ? 22.5 : 14.5, height: LayoutBuilder.mainTop + 5)
    }

    /// The key that sends `event`, if this keyboard has one.
    public func key(for event: KarabinerEvent) -> KeyCap? {
        keys.first { $0.event == event }
    }
}

/// Mouse buttons 1–8 (spec 5.5.2); higher buttons are listed, not drawn.
public enum MouseLayout {
    public static let drawnButtonCount = 8
    public static let size = CGSize(width: 4, height: 6)

    /// Side buttons carry their number, as players name them ("mouse 4"); the full name is in the tooltip.
    public static let buttons: [KeyCap] = [
        button(1, "Left", CGRect(x: 0, y: 0, width: 1.75, height: 2.4)),
        button(3, "3", CGRect(x: 1.75, y: 0.4, width: 0.5, height: 1.3)),
        button(2, "Right", CGRect(x: 2.25, y: 0, width: 1.75, height: 2.4)),
        button(5, "5", CGRect(x: 0.15, y: 2.8, width: 1.1, height: 0.95)),
        button(4, "4", CGRect(x: 0.15, y: 3.85, width: 1.1, height: 0.95)),
        button(6, "6", CGRect(x: 2.75, y: 2.8, width: 1.1, height: 0.95)),
        button(7, "7", CGRect(x: 2.75, y: 3.85, width: 1.1, height: 0.95)),
        button(8, "8", CGRect(x: 2.75, y: 4.9, width: 1.1, height: 0.95)),
    ]

    /// The button number of a `pointing_button` event (`button5` → 5), if it is one.
    public static func buttonNumber(of event: KarabinerEvent) -> Int? {
        guard case .pointing(let code) = event, code.hasPrefix("button") else { return nil }
        return Int(code.dropFirst("button".count))
    }

    private static func button(_ number: Int, _ legend: String, _ frame: CGRect) -> KeyCap {
        KeyCap(event: .pointing("button\(number)"), legend: legend, frames: [frame])
    }
}

/// Places keys row by row, left to right.
private struct LayoutBuilder {
    /// The top of the first main row; the function row sits above it with a small gap.
    static let mainTop: CGFloat = 1.25

    private(set) var keys: [KeyCap] = []
    private var x: CGFloat = 0
    private var y: CGFloat = 0

    private mutating func startRow(_ row: Int, at left: CGFloat = 0) {
        x = left
        y = row < 0 ? 0 : Self.mainTop + CGFloat(row)
    }

    private mutating func key(_ code: String, _ legend: String, _ width: CGFloat = 1) {
        keys.append(KeyCap(event: .key(code), legend: legend, frames: [CGRect(x: x, y: y, width: width, height: 1)]))
        x += width
    }

    private mutating func skip(to left: CGFloat) { x = left }

    private mutating func letters(_ text: String) {
        for character in text { key(String(character), character.uppercased()) }
    }

    private mutating func digits() {
        for digit in [1, 2, 3, 4, 5, 6, 7, 8, 9, 0] { key("\(digit)", "\(digit)") }
    }

    // MARK: Rows

    mutating func addFunctionRow(_ formFactor: KeyboardFormFactor) {
        startRow(-1)
        switch formFactor {
        case .laptop:
            key("escape", "esc", 1.5)
            for number in 1...12 { key("f\(number)", "F\(number)", 13.0 / 12.0) }
        case .fullSize:
            key("escape", "esc")
            for (group, left) in [(1...4, 2.0), (5...8, 6.25), (9...12, 10.5)] {
                skip(to: left)
                for number in group { key("f\(number)", "F\(number)") }
            }
            skip(to: 15)
            for number in 13...15 { key("f\(number)", "F\(number)") }
            skip(to: 18.5)
            for number in 16...19 { key("f\(number)", "F\(number)") }
        }
    }

    mutating func addMainBlock(_ shape: KeyboardShape, _ formFactor: KeyboardFormFactor) {
        // Row 1: numbers.
        startRow(0)
        switch shape {
        case .ansi: key("grave_accent_and_tilde", "`")
        case .iso: key("non_us_backslash", "§")
        case .jis: break
        }
        digits()
        key("hyphen", "-")
        key("equal_sign", shape == .jis ? "^" : "=")
        if shape == .jis { key("international3", "¥") }
        key("delete_or_backspace", "delete", 1.5)

        // Row 2: QWERTY.
        startRow(1)
        key("tab", "tab", 1.5)
        letters("qwertyuiop")
        key("open_bracket", shape == .jis ? "@" : "[")
        key("close_bracket", shape == .jis ? "[" : "]")
        if shape == .ansi { key("backslash", "\\") }

        // Row 3: home row.
        startRow(2)
        if shape == .jis { key("left_control", "control", 1.75) } else { key("caps_lock", "caps lock", 1.75) }
        letters("asdfghjkl")
        key("semicolon", ";")
        key("quote", shape == .jis ? ":" : "'")
        if shape == .ansi {
            key("return_or_enter", "return", 1.75)
        } else {
            key("backslash", shape == .jis ? "]" : "\\")
            let top = Self.mainTop + 1
            keys.append(KeyCap(event: .key("return_or_enter"), legend: "return", frames: [
                CGRect(x: 13.5, y: top, width: 1, height: 1),
                CGRect(x: 13.75, y: top + 1, width: 0.75, height: 1),
            ]))
        }

        // Row 4: shifts.
        startRow(3)
        switch shape {
        case .ansi:
            key("left_shift", "shift", 2.25)
        case .iso:
            key("left_shift", "shift", 1.25)
            key("grave_accent_and_tilde", "`")
        case .jis:
            key("left_shift", "shift", 2.25)
        }
        letters("zxcvbnm")
        key("comma", ",")
        key("period", ".")
        key("slash", "/")
        if shape == .jis {
            key("international1", "_")
            key("right_shift", "shift", 1.25)
        } else {
            key("right_shift", "shift", 2.25)
        }

        // Row 5: modifiers and space.
        startRow(4)
        switch (shape, formFactor) {
        case (.jis, .laptop):
            key("caps_lock", "caps lock")
            key("left_option", "option")
            key("left_command", "command", 1.25)
            key("japanese_eisuu", "英数")
            key("spacebar", "", 4)
            key("japanese_kana", "かな")
            key("right_command", "command", 1.25)
            key("fn", "fn")
            addLaptopArrows()
        case (.jis, .fullSize):
            key("caps_lock", "caps lock", 1.25)
            key("left_option", "option", 1.25)
            key("left_command", "command", 1.5)
            key("japanese_eisuu", "英数", 1.25)
            key("spacebar", "", 4)
            key("japanese_kana", "かな", 1.25)
            key("right_command", "command", 1.5)
            key("right_option", "option", 1.25)
            key("right_control", "control", 1.25)
        case (_, .laptop):
            key("fn", "fn")
            key("left_control", "control")
            key("left_option", "option")
            key("left_command", "command", 1.25)
            key("spacebar", "", 5)
            key("right_command", "command", 1.25)
            key("right_option", "option")
            addLaptopArrows()
        case (_, .fullSize):
            key("left_control", "control", 1.5)
            key("left_option", "option", 1.25)
            key("left_command", "command", 1.5)
            key("spacebar", "", 6)
            key("right_command", "command", 1.5)
            key("right_option", "option", 1.25)
            key("right_control", "control", 1.5)
        }
    }

    /// The inverted T squeezed into the laptop bottom row: up and down share one key's width.
    private mutating func addLaptopArrows() {
        key("left_arrow", "←")
        keys.append(KeyCap(event: .key("up_arrow"), legend: "↑", frames: [CGRect(x: x, y: y, width: 1, height: 0.5)]))
        keys.append(KeyCap(event: .key("down_arrow"), legend: "↓", frames: [CGRect(x: x, y: y + 0.5, width: 1, height: 0.5)]))
        x += 1
        key("right_arrow", "→")
    }

    mutating func addNavigationCluster() {
        startRow(0, at: 15)
        key("fn", "fn")
        key("home", "home")
        key("page_up", "page up")
        startRow(1, at: 15)
        key("delete_forward", "del")
        key("end", "end")
        key("page_down", "page down")
        startRow(3, at: 16)
        key("up_arrow", "↑")
        startRow(4, at: 15)
        key("left_arrow", "←")
        key("down_arrow", "↓")
        key("right_arrow", "→")
    }

    mutating func addKeypad() {
        let left: CGFloat = 18.5
        startRow(0, at: left)
        key("keypad_num_lock", "clear")
        key("keypad_equal_sign", "=")
        key("keypad_slash", "/")
        key("keypad_asterisk", "*")
        startRow(1, at: left)
        for digit in [7, 8, 9] { key("keypad_\(digit)", "\(digit)") }
        key("keypad_hyphen", "-")
        startRow(2, at: left)
        for digit in [4, 5, 6] { key("keypad_\(digit)", "\(digit)") }
        key("keypad_plus", "+")
        startRow(3, at: left)
        for digit in [1, 2, 3] { key("keypad_\(digit)", "\(digit)") }
        keys.append(KeyCap(event: .key("keypad_enter"), legend: "enter", frames: [CGRect(x: x, y: y, width: 1, height: 2)]))
        startRow(4, at: left)
        key("keypad_0", "0", 2)
        key("keypad_period", ".")
    }
}
