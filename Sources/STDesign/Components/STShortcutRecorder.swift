import AppKit
import SwiftUI

// MARK: - Value types

/// Modifier keys of a recorded shortcut. The raw values are the Carbon ones (`cmdKey`, `shiftKey`,
/// `optionKey`, `controlKey`), so a host that registers global hotkeys can pass `rawValue` straight on.
public struct STShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = STShortcutModifiers(rawValue: 1 << 8)
    public static let shift = STShortcutModifiers(rawValue: 1 << 9)
    public static let option = STShortcutModifiers(rawValue: 1 << 11)
    public static let control = STShortcutModifiers(rawValue: 1 << 12)
    public static let all: STShortcutModifiers = [.command, .shift, .option, .control]

    /// The modifiers of an AppKit event (device-dependent bits and Caps Lock are ignored).
    public init(_ flags: NSEvent.ModifierFlags) {
        var result: STShortcutModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }

    /// Mac order: ⌃⌥⇧⌘. Empty when no modifier is set.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// A key press as the recorder reports it: a virtual key code (`kVK_*`, a position on the keyboard)
/// plus modifiers. STDesign cannot depend on STPlatform, so the host converts this to its own type.
public struct STShortcut: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: STShortcutModifiers

    public init(keyCode: UInt16, modifiers: STShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
    }

    /// "⌃⌥C", "⇧F5". Keys the recorder has no name for show as "Key <code>".
    public var display: String {
        modifiers.symbols + (STShortcutKeys.name(for: keyCode) ?? "Key \(keyCode)")
    }
}

/// Key names for the virtual key codes the recorder accepts: every virtual key except the modifier keys, Caps Lock,
/// fn and the system keys. STPlatform's `HotkeyCombo` carries the same names; the app's tests keep the two in step.
enum STShortcutKeys {
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117

    static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static func name(for keyCode: UInt16) -> String? { names[keyCode] }

    private static let names: [UInt16: String] = {
        var table: [UInt16: String] = [:]
        let plain: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"),
            (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"), (43, ","),
            (47, "."), (44, "/"), (50, "`"), (10, "§"), (93, "¥"), (94, "_"),
            (82, "Pad 0"), (83, "Pad 1"), (84, "Pad 2"), (85, "Pad 3"), (86, "Pad 4"), (87, "Pad 5"),
            (88, "Pad 6"), (89, "Pad 7"), (91, "Pad 8"), (92, "Pad 9"), (65, "Pad ."), (67, "Pad *"),
            (69, "Pad +"), (75, "Pad /"), (78, "Pad -"), (81, "Pad ="), (76, "Pad Enter"),
            (71, "Pad Clear"), (95, "Pad ,"),
            (36, "↩"), (48, "⇥"), (49, "Space"), (51, "⌫"), (53, "⎋"), (117, "⌦"),
            (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
            (115, "↖"), (119, "↘"), (116, "⇞"), (121, "⇟"), (102, "英数"), (104, "かな"),
            (114, "Help"), (110, "Menu"),
        ]
        for (code, name) in plain { table[code] = name }
        for (index, code) in functionKeyCodes.enumerated() { table[code] = "F\(index + 1)" }
        return table
    }()
}

// MARK: - Pure logic

/// What a key press means while recording. Pure, no UI.
enum STShortcutRecorderLogic {
    enum Outcome: Equatable {
        case commit(STShortcut)
        case cancel
        case clear
        case reject(String)
    }

    /// The recorder's own minimum: a known key, with or without modifiers. Hosts pass their own `validate` to add
    /// their rules (it replaces this one, so it must refuse unknown keys too).
    static func basicRejection(_ shortcut: STShortcut) -> String? {
        STShortcutKeys.name(for: shortcut.keyCode) == nil ? "That key can't be used" : nil
    }

    /// Esc on its own cancels, Delete or Forward Delete on its own clears; any other key, with or without
    /// modifiers, is a shortcut to validate.
    static func outcome(keyCode: UInt16, modifiers: STShortcutModifiers,
                        validate: (STShortcut) -> String?) -> Outcome {
        if modifiers.isEmpty {
            if keyCode == STShortcutKeys.escape { return .cancel }
            if keyCode == STShortcutKeys.delete || keyCode == STShortcutKeys.forwardDelete { return .clear }
        }
        let shortcut = STShortcut(keyCode: keyCode, modifiers: modifiers)
        if let reason = validate(shortcut) { return .reject(reason) }
        return .commit(shortcut)
    }
}

/// The recorder's state machine. The view feeds it key events; it says what to change.
struct STShortcutRecorderModel: Equatable {
    enum Effect: Equatable {
        case none
        case commit(STShortcut)
        case clear
    }

    private(set) var isRecording = false
    /// Modifiers currently held, shown live while recording.
    private(set) var heldModifiers: STShortcutModifiers = []
    /// Why the last key press was refused; cleared when the next key goes down or modifiers change.
    private(set) var message: String?

    mutating func begin() {
        isRecording = true
        heldModifiers = []
        message = nil
    }

    mutating func cancel() {
        isRecording = false
        heldModifiers = []
        message = nil
    }

    mutating func flagsChanged(_ modifiers: STShortcutModifiers) {
        guard isRecording else { return }
        heldModifiers = modifiers
        message = nil
    }

    mutating func keyDown(keyCode: UInt16, modifiers: STShortcutModifiers,
                          validate: (STShortcut) -> String?) -> Effect {
        guard isRecording else { return .none }
        switch STShortcutRecorderLogic.outcome(keyCode: keyCode, modifiers: modifiers, validate: validate) {
        case .commit(let shortcut):
            cancel()
            return .commit(shortcut)
        case .clear:
            cancel()
            return .clear
        case .cancel:
            cancel()
            return .none
        case .reject(let reason):
            heldModifiers = modifiers
            message = reason
            return .none
        }
    }
}

// MARK: - Event monitor

/// A local `NSEvent` monitor that exists only while recording. It swallows every key press so the
/// shortcut being recorded doesn't also trigger menu commands or type into other controls, and reports
/// clicks (which end recording) and the app losing focus without swallowing them.
/// Tells the app when a field starts and stops listening for raw key presses (a shortcut recorder recording), so
/// global hotkeys can step aside meanwhile and the field gets every key (spec 6.1). The app sets `onChange` once;
/// with none set, nothing happens.
@MainActor
public enum STKeyCapture {
    /// Called with true when the first listener starts and false when the last one stops.
    public static var onChange: (@MainActor (Bool) -> Void)?
    private static var listeners: Set<ObjectIdentifier> = []

    /// Whether any field is listening right now.
    public static var isCapturing: Bool { !listeners.isEmpty }

    static func begin(_ listener: AnyObject) {
        let wasCapturing = isCapturing
        listeners.insert(ObjectIdentifier(listener))
        if !wasCapturing { onChange?(true) }
    }

    static func end(_ listener: AnyObject) {
        guard listeners.remove(ObjectIdentifier(listener)) != nil, !isCapturing else { return }
        onChange?(false)
    }
}

@MainActor
final class STShortcutKeyMonitor {
    enum Event {
        case keyDown(keyCode: UInt16, modifiers: STShortcutModifiers)
        case flagsChanged(STShortcutModifiers)
        /// A click anywhere, or sTools stopped being the active app.
        case interrupted
    }

    private var token: Any?
    private var resignObserver: NSObjectProtocol?
    var isActive: Bool { token != nil }

    func start(_ handle: @escaping @MainActor (Event) -> Void) {
        stop()
        STKeyCapture.begin(self)
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            switch event.type {
            case .keyDown:
                let keyCode = event.keyCode
                let modifiers = STShortcutModifiers(event.modifierFlags)
                MainActor.assumeIsolated { handle(.keyDown(keyCode: keyCode, modifiers: modifiers)) }
                return nil
            case .flagsChanged:
                let modifiers = STShortcutModifiers(event.modifierFlags)
                MainActor.assumeIsolated { handle(.flagsChanged(modifiers)) }
                return event
            default:
                MainActor.assumeIsolated { handle(.interrupted) }
                return event
            }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handle(.interrupted) }
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        STKeyCapture.end(self)
    }
}

// MARK: - View

/// A shortcut field in the house text-field style: `surface` fill, a `stroke` baseline that turns to an
/// accent underline while recording. Click it, or focus it and press Return, to record; then press a key,
/// alone or with any of ⌃ ⌥ ⇧ ⌘. Any known key commits. Esc alone cancels, and Delete or Forward Delete alone
/// clears, so those three can be recorded only with a modifier. Key monitoring runs only while recording; a
/// click anywhere else, or switching to another app, cancels. (Not SwiftUI focus: clicking the field itself
/// makes macOS report a focus change mid-click, which used to cancel recording the moment it began.)
///
/// `validate` returns nil to accept a shortcut or a short reason to refuse it (shown in place of the
/// prompt while recording continues). The default accepts any known key, with or without modifiers.
public struct STShortcutRecorder: View {
    @Binding private var shortcut: STShortcut?
    private let label: String
    private let validate: (STShortcut) -> String?

    @Environment(\.stTheme) private var theme
    @Environment(\.stSoundPlayer) private var sound
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var model = STShortcutRecorderModel()
    @State private var monitor = STShortcutKeyMonitor()

    public init(shortcut: Binding<STShortcut?>, label: String = "Shortcut", validate: ((STShortcut) -> String?)? = nil) {
        _shortcut = shortcut
        self.label = label
        self.validate = validate ?? STShortcutRecorderLogic.basicRejection
    }

    private var bodyFont: Font { STFont.text(14 * theme.textScale) }

    public var body: some View {
        content
            .frame(minWidth: 0, idealWidth: 220, maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.vertical, 6)
            .background(STColor.surface)
            .overlay(alignment: .bottom) { underline }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .focusable(isEnabled)
            .focused($isFocused)
            .focusEffectDisabled()
            // Outside the focus modifiers: inside them, macOS spends the click on giving focus and the tap
            // never fires, so the field turns gold but never starts recording.
            .onTapGesture(perform: startRecording)
            .onKeyPress(.return) {
                guard !model.isRecording else { return .ignored }
                startRecording()
                return .handled
            }
            .onChange(of: model.isRecording) { _, recording in
                if recording { startMonitoring() } else { monitor.stop() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { stopRecording() }
            }
            .onDisappear { stopRecording() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(model.isRecording ? "Press the new key or combination. Escape cancels, Delete clears." : "Activate to record a new key.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, startRecording)
            .accessibilityAction(named: "Clear shortcut") { shortcut = nil }
    }

    @ViewBuilder private var content: some View {
        if model.isRecording {
            if let message = model.message {
                Text(message).stStyle(.label).foregroundStyle(STColor.danger)
            } else if !model.heldModifiers.isEmpty {
                Text(model.heldModifiers.symbols).font(bodyFont).foregroundStyle(STColor.ink)
            } else {
                Text("Press a key…").stStyle(.label).foregroundStyle(theme.inkTertiary)
            }
        } else if let shortcut {
            Text(shortcut.display).font(bodyFont).foregroundStyle(STColor.ink)
        } else {
            Text("Not set").font(bodyFont).foregroundStyle(theme.inkTertiary)
        }
    }

    private var accessibilityValue: String {
        if model.isRecording { return model.message ?? "Recording" }
        return shortcut?.display ?? "Not set"
    }

    private var underline: some View {
        let active = model.isRecording || isFocused
        let rejected = model.isRecording && model.message != nil
        return ZStack {
            Rectangle().fill(theme.stroke)
            Rectangle()
                .fill(rejected ? STColor.danger : theme.accent)
                .scaleEffect(x: active ? 1 : 0, anchor: .leading)
        }
        .frame(height: 1)
        .clipped()
        .stAnimation(STMotion.standard, value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func startRecording() {
        guard isEnabled, !model.isRecording else { return }
        isFocused = true
        model.begin()
    }

    private func stopRecording() {
        guard model.isRecording else { return }
        model.cancel()
        monitor.stop()
    }

    private func startMonitoring() {
        monitor.start { event in
            switch event {
            case .flagsChanged(let modifiers):
                model.flagsChanged(modifiers)
            case .interrupted:
                stopRecording()
            case .keyDown(let keyCode, let modifiers):
                switch model.keyDown(keyCode: keyCode, modifiers: modifiers, validate: validate) {
                case .commit(let recorded):
                    shortcut = recorded
                    sound.play(.click)
                case .clear:
                    shortcut = nil
                case .none:
                    break
                }
            }
        }
    }
}
