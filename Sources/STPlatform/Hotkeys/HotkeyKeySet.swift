import Foundation

/// Home ▸ Hotkeys ▸ Key set (spec 6.1): one hotkey per tool, in sidebar order, each doing that tool's main action.
///
/// A set owns one hotkey per tool, the tool's own hotkey: the first whose only action is the tool's main action (the
/// hotkey a tool page's Hotkey row, or Timer Overlay's Key row, sets). Picking a set changes only those; every
/// other hotkey stays as it is. A new install starts with ⌘1–⌘5.
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

    /// Each tool's main action, in sidebar order: NBB Overlay, Window Backdrop, Crosshair, Timer Overlay (Start
    /// timer) and Screen Recording (its one action, which starts and stops a recording); those two have no toggle.
    /// Key Rebinder has no switch, so it gets no key. The app's `ToolID.hotkeyAction` gives the same actions.
    public static let toolActions: [HotkeyAction] = [
        .toggle(.nbbOverlay), .toggle(.windowBackdrop), .toggle(.crosshair), .startTimer, .startStopRecording,
    ]

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

    /// `bindings` with this set picked: each tool's own hotkey gets the set's key, in its place in the list (added
    /// at the end for a tool without one), or is removed with None. Every other hotkey stays as it is, where it is.
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
        return result
    }
}
