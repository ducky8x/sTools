import Foundation
import Observation

/// What the app should do when a hotkey fires.
public enum HotkeyEvent: Equatable, Sendable {
    /// Switch a tool to a state (the controller must tolerate being told its current state).
    case setTool(HotkeyTool, isOn: Bool)
    /// Start recording if idle, stop if recording.
    case toggleRecording
    /// Start timer was pressed. Timer Overlay's press table decides what that does (spec 5.6.2).
    case startTimer
    /// The key of a press that sent `startTimer` is up again, for the timer's hold-to-cancel (spec 5.6.7). When
    /// that hotkey is unregistered while its key is down, `HotkeyCenter` sends it itself.
    case startTimerReleased
}

/// Why a binding is not active.
public enum HotkeyConflict: Equatable, Sendable {
    /// An earlier binding in the list already uses this combination.
    case alreadyUsedByYou(UUID)
    /// The system refused the registration (another app or macOS owns the combination).
    case systemRefused
    /// The combination itself cannot be a hotkey (a modifier key, a combination macOS keeps, ...).
    case invalidCombo(HotkeyComboIssue)
    /// The binding has no actions.
    case noActions
}

/// Something in sTools listening for raw key presses, which pauses hotkeys while it lasts (spec 6.1).
public enum HotkeyPause: Hashable, Sendable {
    /// A hotkey or shortcut field is recording a key.
    case recordingKey
    /// A text field or text view in sTools is being edited.
    case typing
    /// The Key Rebinder is listening: Test keys, or choosing an output by pressing it.
    case keyRebinder
}

/// The state of one binding.
public enum HotkeyStatus: Equatable, Sendable {
    /// Accepted by macOS, and live wherever hotkeys work (Where hotkeys work), sTools included. While a hotkey pauses
    /// (sTools is recording a key or someone is typing in it) or another app is in front that it doesn't work in, it
    /// isn't registered, but the status stays, so neither ever changes it.
    case registered
    /// Fine, but the master switch is off so nothing is registered.
    case inactive
    case conflict(HotkeyConflict)
}

/// Owns the Hotkeys settings, keeps the system registrations in step with them, and turns presses
/// into `HotkeyEvent`s.
///
/// Rules: with the master switch off nothing is registered. Bindings are checked in list order; the first
/// one to claim a combination keeps it and later duplicates are flagged `.alreadyUsedByYou` (and registered
/// automatically if the first one goes away). A flagged binding stays in the list so the user can fix it.
///
/// Where hotkeys work (`scope`): by default only while sTools or a Minecraft instance is the app in front, as the
/// app's `HotkeyFrontAppWatcher` reports it (`setFrontApp(_:)`); in every other app nothing is registered, so its
/// keys reach that app untouched. With Everywhere they work whichever app is in front.
///
/// Where they work, they pause only while sTools itself listens for raw keys (`setPaused(_:for:)`): a field
/// recording a key, a text field being edited, the Key Rebinder's Test keys or output capture; typing pauses only
/// the hotkeys that would take a typed key. A paused hotkey, like one in an app it doesn't work in, isn't registered
/// and its presses are ignored; a combination macOS hasn't accepted yet this run is still tried once (registered and
/// released at once), so a refusal shows the moment a hotkey is added. When the pause ends, or an app it works in
/// comes to the front, it registers for real.
///
/// A registered hotkey's key that reaches sTools' own window as an ordinary key press (`handleKeyDown`) fires it
/// too, through the same press rules, so a hotkey works in sTools even when macOS hands the key to the window.
///
/// With Also fire while holding Shift or Control on (`alsoFiresWithShiftOrControl`, the default), each hotkey that holds
/// its key also has its variants registered, under ids of their own: the same key with ⇧, ⌃ and ⇧⌃ added, since macOS
/// matches modifiers exactly. A variant's presses and releases are its hotkey's (one press state per hotkey), it steps
/// aside and returns with its hotkey, and one a hotkey of the list, macOS or (while sTools is in front) sTools' own
/// menu has is left out; the saved list never changes.
///
/// Presses count only for a binding registered right now, so a press macOS delivered just before an unregistration
/// is ignored. With a registrar that reports releases, the center also keeps which keys are down: a press for a key
/// that is still down is a repeat and is ignored until its release, a press that sent Start timer gets
/// `.startTimerReleased` when its key comes up, and a release whose press didn't count is ignored, so releases are
/// ignored while paused, as presses are. When a binding whose key is down is unregistered (a pause, the master
/// switch, an edit or removal), macOS can't report that release any more, so the center sends it itself and forgets
/// the key.
///
/// Key events carry the time their key moved, when their source stamps it (macOS through the registrar, the window's
/// `NSEvent`): Start timer's double press and hold measure the keys, not when sTools got to them (`keyEventAge`). The
/// times also keep a missed release from leaving a key dead, since a press over `staleKeyInterval` after the key was
/// last reported is a new one, and tell a second or late report of a press that already counted (macOS and the window
/// both reporting one tap) from a new press. Every key event and every change to what's registered is logged at the
/// notice level, which the unified log keeps and Copy Diagnostics includes.
@MainActor
@Observable
public final class HotkeyCenter {
    public private(set) var settings: HotkeySettings
    /// Advanced ▸ Also fire while holding Shift or Control, stored on its own (`hotkeyHeldModifiers.json`) so `settings`,
    /// the saved hotkey list, is never touched by it.
    public private(set) var heldModifiers: HotkeyHeldModifierSettings
    /// Assigned only when a status really changes, so app switches don't re-render the pages that show them.
    public private(set) var statuses: [UUID: HotkeyStatus] = [:]

    /// What in sTools is listening for raw keys right now; hotkeys pause while any is (`stepsAside(_:)` says which).
    /// Only the app's watchers and the Key Rebinder set them, so a center nobody tells (tests, previews) never pauses.
    @ObservationIgnored public private(set) var pauses: Set<HotkeyPause> = []

    /// The app in front, for Where hotkeys work. Only the app's `HotkeyFrontAppWatcher` sets it, so a center nobody
    /// tells (tests, previews) acts as if sTools were in front. Not observed: app switches never re-render a page.
    @ObservationIgnored public private(set) var frontApp: HotkeyFrontApp = .sTools

    /// Advice from the Key Rebinder: Minecraft cautions, where a hotkey's key is, selecting it. Held weakly; nil
    /// when there is no Key Rebinder.
    @ObservationIgnored public weak var advisor: (any HotkeyAdvising)?

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let registrar: any HotkeyRegistering
    @ObservationIgnored private let toolStates: @MainActor () -> [HotkeyTool: Bool]
    @ObservationIgnored private let handler: @MainActor ([HotkeyEvent]) -> Void
    /// The combinations sTools' own menus use (the Go menu's ⌃⌘0–⌃⌘6, ⌘, ⌘[ and ⌘]), which a variant never takes while
    /// sTools is in front, the only time a menu has them: the app passes them in, since they belong to its menus.
    @ObservationIgnored private let menuShortcuts: Set<HotkeyCombo>
    /// What is registered with the system right now. Empty while paused.
    @ObservationIgnored private var registered: [UUID: HotkeyCombo] = [:]
    /// What is registered beyond the hotkeys themselves while Also fire while holding Shift or Control is on, by the id
    /// each registration was made under: a hotkey's key with Shift and/or Control added, and the hotkey it belongs to.
    @ObservationIgnored private var variants: [UUID: Variant] = [:]
    /// Variants macOS refused this run, so each is logged once however often registrations are brought in step.
    @ObservationIgnored private var refusedVariants: Set<HotkeyCombo> = []
    /// Combinations macOS accepted this run, so a pause tries each one only once. A refusal forgets it again.
    @ObservationIgnored private var accepted: Set<HotkeyCombo> = []
    /// The registered bindings whose key is down: pressed, and not released or unregistered since. A press for one
    /// of them is a repeat, unless the key was last reported over `staleKeyInterval` earlier. Always empty with a
    /// registrar that doesn't report releases, except for presses from sTools' own window.
    @ObservationIgnored private var keysDown: [UUID: KeyDown] = [:]
    /// When each binding's last counted press went down, for presses whose source stamped it: a second report of that
    /// press, or a late one of an earlier press, is told apart from a new one by it.
    @ObservationIgnored private var lastCountedPress: [UUID: TimeInterval] = [:]
    /// While the handler runs, when the key event behind the call happened; nil when its source didn't say.
    @ObservationIgnored private var handlingEventTime: TimeInterval?
    /// The clock key events are stamped on: seconds of system uptime. Tests replace it.
    @ObservationIgnored var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private let log = STLog.logger("Hotkeys")
    /// Whether a hotkey's key has reached the window this run, logged once (spec 6.1's hardware check).
    @ObservationIgnored private var reachedWindow = false
    /// Whether a key event with an unusable time has been logged this run (`usableTime(_:)`).
    @ObservationIgnored private var reportedUnusableTime = false

    /// - Parameters:
    ///   - toolStates: Reports which switchable tools are on right now. Read on every press.
    ///   - menuShortcuts: The combinations sTools' own menus use, which no hotkey's Shift or Control variant takes while
    ///     sTools is the app in front.
    ///   - handler: Receives each press's events together, in order: one per tool change, then one for
    ///     recording, then one for Start timer. One call per press, so the app can confirm the press once.
    ///     A release that ends a Start-timer press comes in a call of its own, `[.startTimerReleased]`.
    public init(store: SettingsStore,
                registrar: any HotkeyRegistering,
                toolStates: @escaping @MainActor () -> [HotkeyTool: Bool],
                menuShortcuts: Set<HotkeyCombo> = [],
                handler: @escaping @MainActor ([HotkeyEvent]) -> Void) {
        self.store = store
        self.registrar = registrar
        self.toolStates = toolStates
        self.menuShortcuts = menuShortcuts
        self.handler = handler
        self.settings = store.load(HotkeySettings.self)
        // Its own file, which nothing writes until the option is changed.
        self.heldModifiers = store.load(HotkeyHeldModifierSettings.self)
        // A file from an earlier version was upgraded as it loaded (an empty version 1 list becomes ⌘1–⌘5 in sidebar
        // order, and build 449's version 2 list goes back to ducky's keys; any other list is kept as it is): writing it
        // back makes that happen once.
        if let stored = store.storedVersion(HotkeySettings.self), stored < HotkeySettings.version {
            store.save(settings)
        }
        registrar.onPress = { [weak self] id in self?.handlePress(id) }
        registrar.onRelease = { [weak self] id in self?.handleRelease(id) }
        synchronize()
    }

    public var isEnabled: Bool {
        get { settings.isEnabled }
        set {
            guard newValue != settings.isEnabled else { return }
            settings.isEnabled = newValue
            commit()
        }
    }

    public var bindings: [HotkeyBinding] { settings.bindings }

    /// Advanced: whether presses show the on-screen confirmation. Stored only; the app reads it.
    public var showsConfirmation: Bool {
        get { settings.showsConfirmation }
        set {
            guard newValue != settings.showsConfirmation else { return }
            settings.showsConfirmation = newValue
            store.save(settings)
        }
    }

    /// Where hotkeys work. Changing it registers or unregisters at once for the app in front.
    public var scope: HotkeyScope {
        get { settings.scope }
        set {
            guard newValue != settings.scope else { return }
            settings.scope = newValue
            commit()
        }
    }

    /// Advanced ▸ Also fire while holding Shift or Control (spec 6.1): on, each hotkey also registers with ⇧, ⌃ and ⇧⌃
    /// added to the modifiers it holds, since macOS matches a hotkey's modifiers exactly, so it works while someone
    /// sneaks or sprints; a press of any of them is that hotkey's own. A variant is left out where its combination is
    /// another hotkey's, one of sTools' own menu shortcuts (while sTools is in front), one macOS keeps, or one macOS
    /// refuses. The saved hotkey list never changes: variants exist only in what is registered. Changing the option
    /// registers or unregisters them at once.
    public var alsoFiresWithShiftOrControl: Bool {
        get { heldModifiers.alsoFiresWithShiftOrControl }
        set {
            guard newValue != heldModifiers.alsoFiresWithShiftOrControl else { return }
            heldModifiers.alsoFiresWithShiftOrControl = newValue
            store.save(heldModifiers)
            synchronize()
        }
    }

    /// Whether hotkeys work in the app in front: always with Everywhere; with In sTools and Minecraft, while sTools
    /// or a Minecraft instance is in front.
    public var worksInFrontApp: Bool { settings.scope == .everywhere || frontApp != .other }

    /// Another app came to the front. Registers or unregisters everything only when that changes whether hotkeys
    /// work there, so most app switches cost a comparison.
    public func setFrontApp(_ app: HotkeyFrontApp) {
        guard app != frontApp else { return }
        let worked = worksInFrontApp
        let menusWereInFront = frontApp == .sTools
        frontApp = app
        // sTools' menu shortcuts count against a hotkey's variants only while sTools is in front, so coming or going
        // changes which variants are registered.
        let menusChanged = (app == .sTools) != menusWereInFront && !menuShortcuts.isEmpty && heldModifiers.alsoFiresWithShiftOrControl
        if worksInFrontApp != worked || menusChanged { synchronize() }
    }

    /// Hotkeys are on but paused, because something in sTools is listening for raw keys. While only typing pauses
    /// them, just the hotkeys that would take a typed key step aside.
    public var isPaused: Bool { settings.isEnabled && !pauses.isEmpty }

    /// Starts or ends a pause for `reason`. Hotkeys come back when the last pause ends.
    public func setPaused(_ paused: Bool, for reason: HotkeyPause) {
        let before = pauses
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
        if pauses != before { synchronize() }
    }

    /// Whether `combo` steps aside right now: every hotkey while the app in front is one hotkeys don't work in, while
    /// a key is recorded or while the Key Rebinder listens; while someone only types, just the ones that would take a
    /// typed character or editing key (`interferesWithTyping`), so F-keys and ⌘ or ⌃ combinations keep working next
    /// to a focused text field.
    private func stepsAside(_ combo: HotkeyCombo) -> Bool {
        guard settings.isEnabled else { return false }
        guard worksInFrontApp else { return true }
        guard !pauses.isEmpty else { return false }
        return pauses == [.typing] ? combo.interferesWithTyping : true
    }

    /// While the master switch is on, the bindings that take their key from the apps they work in: valid, the first
    /// owner of their combination, with actions, and accepted by macOS (live, or stepping aside while sTools listens
    /// for keys or another app is in front). A binding macOS refused takes nothing, so it isn't here. Empty while the
    /// switch is off.
    public var activeBindings: [HotkeyBinding] {
        guard settings.isEnabled else { return [] }
        return settings.bindings.filter { statuses[$0.id] == .registered }
    }

    public func status(of id: UUID) -> HotkeyStatus? { statuses[id] }

    /// Everything the editors say about `combo`, in order: the advisor's cautions, the typing note, the
    /// advisor's other notes, then the fn note. None of them blocks saving.
    public func notes(for combo: HotkeyCombo) -> [HotkeyNote] {
        let advice = advisor?.notes(for: combo) ?? []
        var notes = advice.filter { $0.tone == .caution }
        if let typing = HotkeyWording.typingNote(for: combo, scope: settings.scope) {
            notes.append(HotkeyNote(tone: .note, text: typing))
        }
        notes += advice.filter { $0.tone == .note }
        if let fn = HotkeyWording.functionKeyNote(for: combo) { notes.append(HotkeyNote(tone: .note, text: fn)) }
        return notes
    }

    /// Adds a binding and returns its id. A tool's own hotkey (its only action is one tool's, and the tool had none)
    /// goes in the tool's sidebar place among the own hotkeys, which Home lists first; any other goes at the end
    /// (`HotkeyKeySet.ordered`). A problem shows up in `statuses`. Editors ask before adding a second key for a tool's
    /// action alone (`ownHotkeyReplaced(bySaving:editing:)`).
    @discardableResult
    public func add(combo: HotkeyCombo, actions: [HotkeyAction]) -> UUID {
        let binding = HotkeyBinding(combo: combo, actions: actions)
        settings.bindings = HotkeyKeySet.ordered(settings.bindings + [binding])
        commit()
        return binding.id
    }

    /// Changes a binding's combination and/or actions. Unknown ids are ignored. The list stays `HotkeyKeySet.ordered`:
    /// a binding that becomes a tool's own hotkey moves to the tool's sidebar place, and one that stops being one
    /// follows the own hotkeys, ahead of the bindings that were after it.
    public func update(_ id: UUID, combo: HotkeyCombo? = nil, actions: [HotkeyAction]? = nil) {
        guard let index = settings.bindings.firstIndex(where: { $0.id == id }) else { return }
        var bindings = settings.bindings
        if let combo { bindings[index].combo = combo }
        if let actions { bindings[index].actions = actions.uniqued }
        settings.bindings = HotkeyKeySet.ordered(bindings)
        commit()
    }

    /// Removes a binding. When it was a tool's own hotkey, a second key for that tool alone (an older list can have
    /// one) becomes the tool's own and moves up to its place.
    public func remove(_ id: UUID) {
        settings.bindings = HotkeyKeySet.ordered(settings.bindings.filter { $0.id != id })
        commit()
    }

    // MARK: Key sets

    /// The key set the tools' own hotkeys follow now, or nil when they follow none (Custom).
    public var keySet: HotkeyKeySet? { HotkeyKeySet.current(in: settings.bindings) }

    /// Picks `keySet`, in one change: each tool's own hotkey gets the set's key (one is added where a tool has none;
    /// None, `noKeys`, removes them) and they're listed first, in sidebar order; every other hotkey stays, after them.
    /// Callers ask first when `keySet.replacedEdits(in:)` isn't empty.
    public func apply(_ keySet: HotkeyKeySet) {
        let bindings = keySet.applied(to: settings.bindings)
        guard bindings != settings.bindings else { return }
        settings.bindings = bindings
        commit()
    }

    /// Sets the tool's own hotkey (`HotkeyKeySet.ownBinding`, the one a tool page's Hotkey row edits) to `combo`, in
    /// one change: its key changes and it keeps its id, or a new one is added; nil removes it. The list is then
    /// `HotkeyKeySet.ordered`, so the tools' own hotkeys read in sidebar order, as after picking a key set. Setting the
    /// key it already has, or clearing one it doesn't have, changes nothing.
    public func setOwnHotkey(_ combo: HotkeyCombo?, for action: HotkeyAction) {
        var bindings = settings.bindings
        if let index = bindings.firstIndex(where: { $0.actions == [action] }) {
            guard bindings[index].combo != combo else { return }
            if let combo { bindings[index].combo = combo } else { bindings.remove(at: index) }
        } else {
            guard let combo else { return }
            bindings.append(HotkeyBinding(combo: combo, actions: [action]))
        }
        settings.bindings = HotkeyKeySet.ordered(bindings)
        commit()
    }

    // MARK: One key of its own per tool

    /// The tool's own hotkey that saving `actions` would duplicate, so the editor asks before it does: when `actions`
    /// is one tool's action alone (every action is one tool's), another hotkey already has it alone, and the hotkey
    /// being saved (`id`, nil for a new one) doesn't already. A tool has one key of its own (spec 6.1), so Replace
    /// gives that hotkey the new key (`replaceOwnHotkey(for:with:removing:)`) instead of adding a second. Nil when
    /// saving needs no question: several actions, a tool without a key of its own, the tool's own hotkey edited, or a
    /// second key an older list kept for the tool.
    public func ownHotkeyReplaced(bySaving actions: [HotkeyAction], editing id: UUID?) -> HotkeyBinding? {
        let actions = actions.uniqued
        guard actions.count == 1 else { return nil }
        if let id, settings.bindings.first(where: { $0.id == id })?.actions == actions { return nil }
        return settings.bindings.first { $0.actions == actions && $0.id != id }
    }

    /// Replace, after `ownHotkeyReplaced(bySaving:editing:)`: the tool's own hotkey for `action` gets `combo` and keeps
    /// its id and sidebar place, and the hotkey `id` that was being saved as a second key (nil for a new one) is
    /// removed, in one change. Without another hotkey for `action` alone, `combo` becomes the tool's own: on the hotkey
    /// `id`, or a new one.
    public func replaceOwnHotkey(for action: HotkeyAction, with combo: HotkeyCombo, removing id: UUID?) {
        var bindings = settings.bindings
        if let index = bindings.firstIndex(where: { $0.actions == [action] && $0.id != id }) {
            bindings[index].combo = combo
            bindings.removeAll { $0.id == id }
        } else if let id, let index = bindings.firstIndex(where: { $0.id == id }) {
            bindings[index].combo = combo
            bindings[index].actions = [action]
        } else {
            bindings.append(HotkeyBinding(combo: combo, actions: [action]))
        }
        settings.bindings = HotkeyKeySet.ordered(bindings)
        commit()
    }

    /// Why `combo` could not be added right now, ignoring the binding `id` (pass it when editing that
    /// binding). For checking a combination before the user commits it. A system refusal can only be
    /// found by really registering, so it is reported on the binding's status instead.
    public func conflict(for combo: HotkeyCombo, excluding id: UUID? = nil) -> HotkeyConflict? {
        if let issue = combo.issue { return .invalidCombo(issue) }
        if let owner = settings.bindings.first(where: { $0.combo == combo && $0.id != id }) {
            return .alreadyUsedByYou(owner.id)
        }
        return nil
    }

    // MARK: Keys in sTools' own window

    /// A key went down in sTools' own window at `time` (the event's `timestamp`, system uptime): macOS handed it to the
    /// window instead of turning it into a hotkey press. When a registered hotkey has exactly this key and these
    /// modifiers, or a variant of one does (Also fire while holding Shift or Control), it fires as a press from macOS
    /// would (a repeat, or a press macOS reported too, is ignored) and this returns true, so the window doesn't also
    /// type it. False while hotkeys are off or paused, or when no hotkey has this combination.
    @discardableResult
    public func handleKeyDown(keyCode: UInt16, modifiers: HotkeyCombo.Modifiers, isRepeat: Bool,
                              at time: TimeInterval? = nil) -> Bool {
        let combo = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        // Only a live registration counts: a paused one is unregistered, so its key goes on to the field.
        guard let id = liveOwner(of: combo) else { return false }
        if !reachedWindow {
            reachedWindow = true
            log.notice("A hotkey's key reached sTools' window: \(combo.displayString, privacy: .public)")
        }
        if isRepeat {
            // Held in the window: it keeps its press alive and is never a new one.
            keysDown[id]?.lastReport = usableTime(time) ?? uptime()
            return true
        }
        handlePress(id, combo: combo, from: .window, at: time)
        return true
    }

    /// The hotkey that has `combo` registered right now: its own key, or one of its variants.
    private func liveOwner(of combo: HotkeyCombo) -> UUID? {
        registered.first(where: { $0.value == combo })?.key ?? variants.values.first(where: { $0.combo == combo })?.owner
    }

    /// A key came up in sTools' own window at `time`. Ends the press of each hotkey on this key whose press came from
    /// the window; true when there was one.
    @discardableResult
    public func handleKeyUp(keyCode: UInt16, at time: TimeInterval? = nil) -> Bool {
        let ids = keysDown.filter { $0.value.fromWindow && $0.value.combo.keyCode == keyCode }.map(\.key)
        for id in ids {
            handleRelease(id, from: .window, at: time)
        }
        return !ids.isEmpty
    }

    /// sTools stopped being the active app, so the window won't see the release of a key pressed in it: ends those
    /// presses now.
    public func releaseWindowKeys() {
        for id in keysDown.filter({ $0.value.fromWindow }).map(\.key) {
            handleRelease(id, from: .sTools, at: nil)
        }
    }

    // MARK: Key timing

    /// A key reported down again this soon after it was last reported, with no release between, is held (a repeat).
    /// Any later, its release was missed and the press is a new one, so a lost release never leaves a key dead. Longer
    /// than macOS's key repeat interval, so a held key's repeats, if macOS sends any, keep it down.
    public static let staleKeyInterval: TimeInterval = 1
    /// A press stamped this close to the last one that counted for its hotkey, or earlier, is that press again (macOS
    /// and sTools' window both reporting one tap) or a late report of an earlier one.
    static let sameKeyEventTolerance: TimeInterval = 0.005
    /// A key event stamped longer ago than this, or ahead of now, carries a time that can't be its key's (0, or
    /// another clock): it counts as unstamped.
    static let oldestKeyEvent: TimeInterval = 60
    /// How far ahead of now a key event may be stamped (two clocks a hair apart) and still be believed; it then
    /// happened now.
    static let futureKeyEventTolerance: TimeInterval = 0.1

    /// While the handler runs, how long ago the key event behind the call happened, read when asked: the time sTools
    /// took to get to it. 0 when its source didn't stamp it, for the releases the center sends itself, and outside a
    /// handler call. Start timer takes it off its press, so its 0.4 s double press and 1 s hold measure the keys
    /// (spec 5.6.2).
    public var keyEventAge: TimeInterval {
        guard let handlingEventTime else { return 0 }
        return max(0, uptime() - handlingEventTime)
    }

    // MARK: Internals

    private func commit() {
        store.save(settings)
        synchronize()
    }

    /// Whether the registrar reports releases. One that keeps the protocol's default `onRelease` reads nil: with it,
    /// no key is ever marked down.
    private var reportsReleases: Bool { registrar.onRelease != nil }

    /// A key that is down, in `keysDown`, under the id of the hotkey it fires.
    private struct KeyDown {
        /// The combination the press matched: the hotkey's own, or one of its variants.
        var combo: HotkeyCombo
        /// Whether its press sent Start timer, so its release sends `.startTimerReleased`.
        var startsTimer: Bool
        /// Whether its press came from sTools' own window, whose release comes from there too.
        var fromWindow: Bool
        /// When it went down, and when it was last reported (its press or a repeat), on the uptime clock.
        var downAt: TimeInterval
        var lastReport: TimeInterval
        /// The repeats since its press, so only the first one is logged.
        var repeats = 0
    }

    /// A combination registered for a hotkey beyond its own: its key with Shift and/or Control added.
    private struct Variant: Hashable {
        /// The hotkey that fires when it is pressed.
        let owner: UUID
        let combo: HotkeyCombo
    }

    /// Where a key event came from, for the log.
    private enum KeySource: String {
        case macOS
        case window = "sTools' window"
        case sTools = "sTools itself"
    }

    /// The hotkey and the combination behind a registration made under `id`, while it is live: a hotkey's own, or a
    /// variant of it.
    private func liveRegistration(_ id: UUID) -> (owner: UUID, combo: HotkeyCombo)? {
        if let combo = registered[id] { return (id, combo) }
        if let variant = variants[id] { return (variant.owner, variant.combo) }
        return nil
    }

    /// A press from the registrar, stamped with its event's time when the registrar knows it.
    private func handlePress(_ id: UUID) {
        guard let live = liveRegistration(id) else {
            log.notice("A press from \(KeySource.macOS.rawValue, privacy: .public) of a hotkey that isn't live now was ignored")
            return
        }
        handlePress(live.owner, combo: live.combo, from: .macOS, at: registrar.eventTime)
    }

    /// A release from the registrar. A variant's release ends its hotkey's press, as the hotkey's own does.
    private func handleRelease(_ id: UUID) {
        let live = liveRegistration(id)
        handleRelease(live?.owner ?? id, from: .macOS, at: registrar.eventTime, combo: live?.combo)
    }

    /// A press counts only for a binding registered right now: nothing is while hotkeys are off or paused, and a
    /// press macOS delivered just before an unregistration is stale. A press for a key that is still down is a
    /// repeat and is ignored until its release, so a held key never looks like a double press (which cancels the
    /// timer); separate presses still count. A key last reported over `staleKeyInterval` earlier lost its release,
    /// so its press counts. A stamped press no later than the last counted one is a second or late report of a press
    /// that already counted. Whether macOS repeats held hotkeys or ever drops a release is to be confirmed on hardware
    /// (spec 6.1); the log says what happened.
    private func handlePress(_ id: UUID, combo: HotkeyCombo, from source: KeySource, at stamp: TimeInterval?) {
        let stamped = usableTime(stamp)
        guard let binding = settings.bindings.first(where: { $0.id == id }) else {
            log.notice("A press from \(source.rawValue, privacy: .public) of a hotkey that isn't live now was ignored")
            return
        }
        let time = stamped ?? uptime()
        let key = Self.describe(combo, from: source, at: stamped)
        if let stamped, let last = lastCountedPress[id], stamped <= last + Self.sameKeyEventTolerance {
            log.notice("\(key, privacy: .public) down: ignored, a press that already counted")
            return
        }
        if reportsReleases || source == .window {
            if let down = keysDown[id] {
                let quiet = time - down.lastReport
                if quiet <= Self.staleKeyInterval {
                    keysDown[id]?.lastReport = max(down.lastReport, time)
                    keysDown[id]?.repeats += 1
                    if down.repeats == 0 { log.notice("\(key, privacy: .public) down: ignored, still held (a repeat)") }
                    return
                }
                log.notice("\(key, privacy: .public) down: its release never came (last seen \(quiet, format: .fixed(precision: 2), privacy: .public) s before), so this press is new")
            }
            keysDown[id] = KeyDown(combo: combo, startsTimer: binding.actions.contains(.startTimer),
                                   fromWindow: source == .window, downAt: time, lastReport: time)
        }
        if let stamped { lastCountedPress[id] = stamped }
        let outcome = HotkeyAction.resolve(binding.actions, toolStates: toolStates())
        var events = outcome.toolChanges.map { HotkeyEvent.setTool($0.tool, isOn: $0.isOn) }
        if outcome.togglesRecording { events.append(.toggleRecording) }
        if outcome.startsTimer { events.append(.startTimer) }
        log.notice("\(key, privacy: .public) down: counted, \(Self.describe(events), privacy: .public)")
        guard !events.isEmpty else { return }
        send(events, stampedAt: stamped)
    }

    /// A release counts only for a key whose press counted, and sends an event only when that press sent Start
    /// timer. A stamped release from before its key's press is a late report of an earlier release, so it ends nothing.
    private func handleRelease(_ id: UUID, from source: KeySource, at stamp: TimeInterval?, combo: HotkeyCombo? = nil) {
        let stamped = usableTime(stamp)
        let key = Self.describe(combo ?? keysDown[id]?.combo ?? registered[id], from: source, at: stamped)
        guard let down = keysDown[id] else {
            log.notice("\(key, privacy: .public) up: ignored, no press of it counted")
            return
        }
        if let stamped, stamped + Self.sameKeyEventTolerance < down.downAt {
            log.notice("\(key, privacy: .public) up: ignored, older than the press it would end")
            return
        }
        keysDown[id] = nil
        log.notice("\(key, privacy: .public) up: ends its press\(down.startsTimer ? ", Start timer released" : "", privacy: .public)")
        guard down.startsTimer else { return }
        send([.startTimerReleased], stampedAt: stamped)
    }

    /// A key event's own time when it's believable: no later than now (beyond a hair) and no older than
    /// `oldestKeyEvent`. Anything else is a time that can't be its key's, so the event counts as unstamped, from when
    /// sTools got to it; the first one is logged.
    private func usableTime(_ stamp: TimeInterval?) -> TimeInterval? {
        guard let stamp else { return nil }
        let now = uptime()
        if stamp > now - Self.oldestKeyEvent, stamp < now + Self.futureKeyEventTolerance { return stamp }
        if !reportedUnusableTime {
            reportedUnusableTime = true
            let line = String(format: "A key event's time (%.3f) is too far from now (%.3f), so key events without a usable time count from when sTools gets to them", stamp, now)
            log.notice("\(line, privacy: .public)")
        }
        return nil
    }

    /// Calls the handler with `events`, saying when their key event happened while it runs (`keyEventAge`).
    private func send(_ events: [HotkeyEvent], stampedAt time: TimeInterval?) {
        let outer = handlingEventTime
        handlingEventTime = time
        defer { handlingEventTime = outer }
        handler(events)
    }

    /// "⌘2 from macOS at 1234.567": a key event, for the log.
    private static func describe(_ combo: HotkeyCombo?, from source: KeySource, at time: TimeInterval?) -> String {
        let name = combo?.displayString ?? "A hotkey"
        let when = time.map { String(format: " at %.3f", $0) } ?? ""
        return "\(name) from \(source.rawValue)\(when)"
    }

    /// What a press sends, for the log: "Crosshair on, Start timer".
    private static func describe(_ events: [HotkeyEvent]) -> String {
        guard !events.isEmpty else { return "nothing to do" }
        return events.map { event in
            switch event {
            case .setTool(let tool, let isOn): "\(tool.rawValue) \(isOn ? "on" : "off")"
            case .toggleRecording: "Screen Recording"
            case .startTimer: "Start timer"
            case .startTimerReleased: "Start timer released"
            }
        }.joined(separator: ", ")
    }

    /// What is live now and why, for the log: every change to what's registered with macOS is logged.
    private func logRegistrations() {
        let live = settings.bindings.compactMap { registered[$0.id]?.displayString }
        let more = variants.isEmpty ? "" : " and \(variants.count) more with Shift or Control held"
        let why = if !settings.isEnabled {
            "hotkeys are off"
        } else if !worksInFrontApp {
            "another app is in front"
        } else if !pauses.isEmpty {
            "paused while sTools listens for keys: \(pauses.map { "\($0)" }.sorted().joined(separator: ", "))"
        } else {
            "\(frontApp) is in front"
        }
        let line = "\(live.isEmpty ? "none" : live.joined(separator: " "))\(more) (\(why); Where hotkeys work: \(settings.scope.title))"
        log.notice("Hotkeys live: \(line, privacy: .public)")
    }

    /// Brings registrations and statuses in line with the settings: unregisters what is no longer wanted,
    /// registers what is new or changed, leaves unchanged registrations alone. While paused, or while an app hotkeys
    /// don't work in is in front, it unregisters what steps aside and only tries combinations macOS hasn't accepted
    /// yet. An unregistered key that was down gets its release from here, once everything else is up to date.
    private func synchronize() {
        var wanted: [UUID: HotkeyCombo] = [:]
        var newStatuses: [UUID: HotkeyStatus] = [:]
        var owners: [HotkeyCombo: UUID] = [:]

        for binding in settings.bindings {
            if binding.actions.isEmpty {
                newStatuses[binding.id] = .conflict(.noActions)
            } else if let issue = binding.combo.issue {
                newStatuses[binding.id] = .conflict(.invalidCombo(issue))
            } else if let owner = owners[binding.combo] {
                newStatuses[binding.id] = .conflict(.alreadyUsedByYou(owner))
            } else {
                owners[binding.combo] = binding.id
                if settings.isEnabled {
                    wanted[binding.id] = binding.combo
                } else {
                    newStatuses[binding.id] = .inactive
                }
            }
        }

        // Variants are planned from the hotkeys that want their keys, before anything is registered, so a variant that
        // is no longer wanted (a hotkey was added on its combination, say) is gone before a hotkey registers it.
        let wantedVariants = plannedVariants(wanted: wanted)
        let wasLive = registered
        let wasLiveVariants = variants
        var timerReleases = 0
        for (id, combo) in registered where stepsAside(combo) || wanted[id] != combo {
            registrar.unregister(id: id)
            registered[id] = nil
            // macOS can't report this key's release any more.
            lastCountedPress[id] = nil
            if let down = keysDown.removeValue(forKey: id) {
                let key = Self.describe(combo, from: .sTools, at: nil)
                log.notice("\(key, privacy: .public) up: its hotkey stood aside while the key was down\(down.startsTimer ? ", Start timer released" : "", privacy: .public)")
                if down.startsTimer { timerReleases += 1 }
            }
        }
        for (id, variant) in variants where stepsAside(variant.combo) || !wantedVariants.contains(variant) {
            registrar.unregister(id: id)
            variants[id] = nil
            // The same for a press that came through this variant: the key is its hotkey's, and macOS can't report it.
            if let down = keysDown[variant.owner], down.combo == variant.combo {
                keysDown[variant.owner] = nil
                let key = Self.describe(variant.combo, from: .sTools, at: nil)
                log.notice("\(key, privacy: .public) up: its hotkey stood aside while the key was down\(down.startsTimer ? ", Start timer released" : "", privacy: .public)")
                if down.startsTimer { timerReleases += 1 }
            }
        }
        for binding in settings.bindings {
            guard let combo = wanted[binding.id] else { continue }
            if stepsAside(combo) {
                newStatuses[binding.id] = probe(combo, id: binding.id)
            } else if registered[binding.id] == combo {
                newStatuses[binding.id] = .registered
            } else if register(combo, id: binding.id) {
                registered[binding.id] = combo
                newStatuses[binding.id] = .registered
            } else {
                newStatuses[binding.id] = .conflict(.systemRefused)
            }
        }
        // A hotkey macOS refused (or that another owns) has no variants: only one that holds its key gets them.
        for variant in wantedVariants where newStatuses[variant.owner] == .registered && !stepsAside(variant.combo)
            && !variants.values.contains(variant) {
            register(variant)
        }
        if newStatuses != statuses { statuses = newStatuses }
        if registered != wasLive || variants != wasLiveVariants { logRegistrations() }
        for _ in 0..<timerReleases { send([.startTimerReleased], stampedAt: nil) }
    }

    /// What `synchronize()` registers beyond the hotkeys' own while Also fire while holding Shift or Control is on: each
    /// hotkey that wants its key, with ⇧, ⌃ and ⇧⌃ added to what it holds, in list order. A variant is left out when it
    /// is a combination of the list (every hotkey's own wins, whatever its place, and an earlier hotkey's variant wins
    /// over a later one's), one macOS keeps (`HotkeyCombo.issue`, and the screenshots to the clipboard, which no hotkey
    /// may hold either), or, while sTools is the app in front, one of its own menu shortcuts (a menu exists only
    /// then, so in the game ⌘1 also fires with Control held), so a hotkey never takes what another has.
    private func plannedVariants(wanted: [UUID: HotkeyCombo]) -> [Variant] {
        guard settings.isEnabled, heldModifiers.alsoFiresWithShiftOrControl else { return [] }
        let menus = frontApp == .sTools ? menuShortcuts : []
        var taken = Set(settings.bindings.map(\.combo))
        var planned: [Variant] = []
        for binding in settings.bindings where wanted[binding.id] != nil {
            for combo in binding.combo.shiftAndControlVariants {
                guard combo.issue == nil, !Self.macOSKeepsForVariants.contains(combo), !menus.contains(combo),
                      taken.insert(combo).inserted else { continue }
                planned.append(Variant(owner: binding.id, combo: combo))
            }
        }
        return planned
    }

    /// What macOS keeps that `HotkeyCombo.issue` doesn't list, because it only matters to a variant (a hotkey's own
    /// key has always been the person's choice): ⌃⇧⌘3 and ⌃⇧⌘4 take a screenshot to the clipboard.
    private static let macOSKeepsForVariants: Set<HotkeyCombo> = [
        HotkeyCombo(keyCode: 20, modifiers: [.control, .shift, .command]),
        HotkeyCombo(keyCode: 21, modifiers: [.control, .shift, .command]),
    ]

    /// Registers a variant under an id of its own. macOS refusing it only leaves it out (logged once): the hotkey and
    /// its other variants are unaffected.
    private func register(_ variant: Variant) {
        let id = UUID()
        do {
            try registrar.register(variant.combo, id: id)
            variants[id] = variant
            refusedVariants.remove(variant.combo)
        } catch {
            if refusedVariants.insert(variant.combo).inserted {
                log.notice("macOS refused \(variant.combo.displayString, privacy: .public), so it is left out (\(String(describing: error), privacy: .public))")
            }
        }
    }

    /// While stepping aside: a combination macOS accepted before is fine; anything else is registered and released
    /// in the same turn, so a refusal still shows at once.
    private func probe(_ combo: HotkeyCombo, id: UUID) -> HotkeyStatus {
        if accepted.contains(combo) { return .registered }
        guard register(combo, id: id) else { return .conflict(.systemRefused) }
        registrar.unregister(id: id)
        return .registered
    }

    /// Registers with the system and remembers the answer: accepted combinations aren't tried again while paused,
    /// and a refusal forgets an earlier acceptance.
    private func register(_ combo: HotkeyCombo, id: UUID) -> Bool {
        do {
            try registrar.register(combo, id: id)
            accepted.insert(combo)
            return true
        } catch {
            log.error("System refused \(combo.displayString, privacy: .public): \(String(describing: error), privacy: .public)")
            accepted.remove(combo)
            return false
        }
    }
}
