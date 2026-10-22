import Foundation
import STPlatform

/// What the Timer page's key row shows (spec 5.6.2): every Start-timer hotkey in Home ▸ Hotkeys' order, each with its
/// key and its problem if it has one, whether Hotkeys are on, and where they work and the key set (spec 6.1). The app
/// fills it in from `HotkeyCenter`, so the timer never registers a key of its own (spec 5.6.10). The words are
/// placeholder wording for M9.
public struct TimerKeyStatus: Equatable, Sendable {
    /// One Start-timer hotkey.
    public struct Key: Equatable, Sendable, Identifiable {
        /// The hotkey's binding ID in Home ▸ Hotkeys.
        public let id: UUID
        /// The combination as Home shows it: "F13", "⇧⌘2".
        public let name: String
        /// Why it can't work, when it can't: "Refused by macOS", "Already used by another hotkey".
        public let problem: String?

        public init(id: UUID, name: String, problem: String? = nil) {
            self.id = id
            self.name = name
            self.problem = problem
        }
    }

    /// The Start-timer hotkeys, in Home's order. Empty: "No key yet".
    public var keys: [Key]
    /// Whether the Hotkeys master switch is on. A Start-timer key works only while it is (spec 5.6.2).
    public var hotkeysAreOn: Bool
    /// Where hotkeys work (Home ▸ Hotkeys), for the row's line under the key.
    public var scope: HotkeyScope
    /// The key set the tools' own hotkeys follow, the Start-timer key among them; nil when they follow none (Custom).
    public var keySet: HotkeyKeySet?
    /// Whether Accessibility is allowed. Recognizing Minecraft needs it, so without it In sTools and Minecraft works
    /// only in sTools, and the line under the key says so, as Home does.
    public var accessibilityGranted: Bool

    /// `keySet` defaults to None, an empty list's.
    public init(keys: [Key] = [], hotkeysAreOn: Bool = false, scope: HotkeyScope = .sToolsAndMinecraft,
                keySet: HotkeyKeySet? = .noKeys, accessibilityGranted: Bool = true) {
        self.keys = keys
        self.hotkeysAreOn = hotkeysAreOn
        self.scope = scope
        self.keySet = keySet
        self.accessibilityGranted = accessibilityGranted
    }

    /// The hotkeys among `bindings` that hold Start timer, in their order, each with the problem `status` reports, and
    /// the key set `bindings` follow.
    public init(bindings: [HotkeyBinding], hotkeysAreOn: Bool, scope: HotkeyScope = .sToolsAndMinecraft,
                accessibilityGranted: Bool = true, status: (UUID) -> HotkeyStatus?) {
        keys = bindings.filter { $0.actions.contains(.startTimer) }.map { binding in
            Key(id: binding.id, name: binding.combo.displayString,
                problem: HotkeyWording.statusNote(status(binding.id), combo: binding.combo, inList: false))
        }
        self.hotkeysAreOn = hotkeysAreOn
        self.scope = scope
        keySet = HotkeyKeySet.current(in: bindings)
        self.accessibilityGranted = accessibilityGranted
    }

    /// The key row for `hotkeys` as they are now, with Accessibility allowed or not.
    @MainActor
    public init(hotkeys: HotkeyCenter, accessibilityGranted: Bool = true) {
        self.init(bindings: hotkeys.bindings, hotkeysAreOn: hotkeys.isEnabled, scope: hotkeys.scope,
                  accessibilityGranted: accessibilityGranted, status: { hotkeys.status(of: $0) })
    }

    /// No Start-timer hotkey, with Hotkeys off.
    public static let noKey = TimerKeyStatus()

    public var hasKey: Bool { !keys.isEmpty }

    /// "Start timer: F13", "Start timer: F13 or ⇧⌘2", or "No key yet".
    public var title: String {
        guard !keys.isEmpty else { return "No key yet" }
        return "Start timer: " + Self.list(keys.map(\.name))
    }

    /// "F13", "F13 or ⇧⌘2", "F13, F14 or ⇧⌘2".
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }
}
