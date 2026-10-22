import Foundation

/// Home ▸ Hotkeys ▸ Key set (spec 6.1): one hotkey per tool, in sidebar order, each doing that tool's main action.
///
/// A set owns one hotkey per tool, the tool's own hotkey: the first whose only action is the tool's main action (the
/// hotkey a tool page's Hotkey row, or Timer Overlay's Key row, sets). Picking a set changes only those and lists
/// them first, in sidebar order; every other hotkey stays as it is, after them. A new install starts with ⌘1–⌘5.
public enum HotkeyKeySet: String, CaseIterable, Hashable, Sendable {
    /// ⌘1–⌘5, a new install's.
    case command
    /// ⌃1–⌃5.
    case control
    /// ⌥1–⌥5.
    case option
    /// F13–F17.
    case functionKeys
    /// No key for any tool ("None"; not `none`, which would read as `Optional.none` next to `keySet`).
    case noKeys

    /// The set a new install starts with.
    public static let newInstall: HotkeyKeySet = .command

    /// Each tool's main action, in sidebar order (`HotkeyAction.allCases`): Crosshair, Timer Overlay (Start timer),
    /// NBB Overlay, Screen Recording (its one action, which starts and stops a recording) and Window Backdrop; Timer
    /// Overlay and Screen Recording have no toggle. Key Rebinder, last in the sidebar, has no switch, so it gets no
    /// key and each tool's digit is its sidebar number. The app's `ToolID.hotkeyAction` gives the same actions.
    public static var toolActions: [HotkeyAction] { HotkeyAction.allCases }

    /// The set's name in the chooser.
    public var title: String {
        switch self {
        case .command: "⌘1–⌘5"
        case .control: "⌃1–⌃5"
        case .option: "⌥1–⌥5"
        case .functionKeys: "F13–F17"
        case .noKeys: "None"
        }
    }

    /// The set's name as VoiceOver says it, in words like a hotkey's keys (`HotkeyWording.spokenName(for:)`): "Command
    /// 1 to Command 5", "F13 to F17", "None".
    public var spokenTitle: String {
        guard let first = combos.first, let last = combos.last else { return title }
        return "\(HotkeyWording.spokenName(for: first)) to \(HotkeyWording.spokenName(for: last))"
    }

    /// What the tools' own hotkeys follow, by name: the set's title, or Custom when they follow none (`current(in:)`
    /// is nil) because a key was set by hand.
    public static func name(of set: HotkeyKeySet?) -> String { set?.title ?? "Custom" }

    /// The digits 1 to 5 on the main row, and F13 to F17, as virtual key codes.
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23]
    private static let functionKeyCodes: [UInt16] = [105, 107, 113, 106, 64]

    /// The key this set gives the tool whose main action is `action`: nil with None, or for an action that is no
    /// tool's main action.
    public func combo(for action: HotkeyAction) -> HotkeyCombo? {
        guard let index = Self.toolActions.firstIndex(of: action) else { return nil }
        let digit = Self.digitKeyCodes[index]
        return switch self {
        case .command: HotkeyCombo(keyCode: digit, modifiers: .command)
        case .control: HotkeyCombo(keyCode: digit, modifiers: .control)
        case .option: HotkeyCombo(keyCode: digit, modifiers: .option)
        case .functionKeys: HotkeyCombo(keyCode: Self.functionKeyCodes[index], modifiers: [])
        case .noKeys: nil
        }
    }

    /// Every key the set gives, in sidebar order.
    public var combos: [HotkeyCombo] { Self.toolActions.compactMap(combo(for:)) }

    /// A list of just this set's hotkeys, in sidebar order: a new install's.
    public func bindings() -> [HotkeyBinding] {
        Self.toolActions.compactMap { action in combo(for: action).map { HotkeyBinding(combo: $0, actions: [action]) } }
    }

    /// The tool's own hotkey: the first whose only action is `action`.
    public static func ownBinding(for action: HotkeyAction, in bindings: [HotkeyBinding]) -> HotkeyBinding? {
        bindings.first { $0.actions == [action] }
    }

    /// The set the tools' own hotkeys follow: each has this set's key (with None, `noKeys`, no tool has one). Nil when they
    /// follow none, because a key was set by hand or a tool's hotkey is missing.
    public static func current(in bindings: [HotkeyBinding]) -> HotkeyKeySet? {
        allCases.first { set in
            toolActions.allSatisfy { ownBinding(for: $0, in: bindings)?.combo == set.combo(for: $0) }
        }
    }

    /// The tools' own hotkeys that picking this set would change or remove although their key is one no set gives
    /// that tool: keys set by hand, which the chooser asks about first.
    public func replacedEdits(in bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        Self.toolActions.compactMap { action in
            guard let own = Self.ownBinding(for: action, in: bindings), own.combo != combo(for: action),
                  !Self.allCases.contains(where: { $0.combo(for: action) == own.combo }) else { return nil }
            return own
        }
    }

    /// `bindings` with this set picked: each tool's own hotkey gets the set's key and keeps its id (one is added for a
    /// tool without), or is removed with None. The result is `ordered`: the tools' own hotkeys first, in sidebar order,
    /// then every other hotkey as it was, in its order.
    public func applied(to bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        var result = bindings
        for action in Self.toolActions {
            let key = combo(for: action)
            if let index = result.firstIndex(where: { $0.actions == [action] }) {
                if let key { result[index].combo = key } else { result.remove(at: index) }
            } else if let key {
                result.append(HotkeyBinding(combo: key, actions: [action]))
            }
        }
        return Self.ordered(result)
    }

    /// The order Home lists hotkeys in once a key set or a tool page has set a tool's key: the tools' own hotkeys first,
    /// in sidebar order (⌘1 to ⌘5 down the page), then every other hotkey in its order. Only own hotkeys move, so a
    /// list already in this order comes back unchanged.
    public static func ordered(_ bindings: [HotkeyBinding]) -> [HotkeyBinding] {
        let own = toolActions.compactMap { ownBinding(for: $0, in: bindings) }
        let ownIDs = Set(own.map(\.id))
        return own + bindings.filter { !ownIDs.contains($0.id) }
    }
}
