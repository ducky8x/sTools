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
/// Presses count only for a binding registered right now, so a press macOS delivered just before an unregistration
/// is ignored. With a registrar that reports releases, the center also keeps which keys are down: a press for a key
/// that is still down is a repeat and is ignored until its release, a press that sent Start timer gets
/// `.startTimerReleased` when its key comes up, and a release whose press didn't count is ignored, so releases are
/// ignored while paused, as presses are. When a binding whose key is down is unregistered (a pause, the master
/// switch, an edit or removal), macOS can't report that release any more, so the center sends it itself and forgets
/// the key.
@MainActor
@Observable
public final class HotkeyCenter {
    public private(set) var settings: HotkeySettings
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
    /// What is registered with the system right now. Empty while paused.
    @ObservationIgnored private var registered: [UUID: HotkeyCombo] = [:]
    /// Combinations macOS accepted this run, so a pause tries each one only once. A refusal forgets it again.
    @ObservationIgnored private var accepted: Set<HotkeyCombo> = []
    /// The registered bindings whose key is down: pressed, and not released or unregistered since. A press for one
    /// of them is a repeat. Each says whether its press sent Start timer, so its release sends `.startTimerReleased`.
    /// Always empty with a registrar that doesn't report releases, except for presses from sTools' own window.
    @ObservationIgnored private var keysDown: [UUID: Bool] = [:]
    /// The keys in `keysDown` whose press came from sTools' own window, whose release comes from there too.
    @ObservationIgnored private var appKeysDown: Set<UUID> = []
    @ObservationIgnored private let log = STLog.logger("Hotkeys")
    /// Whether a hotkey's key has reached the window this run, logged once (spec 6.1's hardware check).
    @ObservationIgnored private var reachedWindow = false

    /// - Parameters:
    ///   - toolStates: Reports which switchable tools are on right now. Read on every press.
    ///   - handler: Receives each press's events together, in order: one per tool change, then one for
    ///     recording, then one for Start timer. One call per press, so the app can confirm the press once.
    ///     A release that ends a Start-timer press comes in a call of its own, `[.startTimerReleased]`.
    public init(store: SettingsStore,
                registrar: any HotkeyRegistering,
                toolStates: @escaping @MainActor () -> [HotkeyTool: Bool],
                handler: @escaping @MainActor ([HotkeyEvent]) -> Void) {
        self.store = store
        self.registrar = registrar
        self.toolStates = toolStates
        self.handler = handler
        self.settings = store.load(HotkeySettings.self)
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

    /// Whether hotkeys work in the app in front: always with Everywhere; with In sTools and Minecraft, while sTools
    /// or a Minecraft instance is in front.
    public var worksInFrontApp: Bool { settings.scope == .everywhere || frontApp != .other }

    /// Another app came to the front. Registers or unregisters everything only when that changes whether hotkeys
    /// work there, so most app switches cost a comparison.
    public func setFrontApp(_ app: HotkeyFrontApp) {
        guard app != frontApp else { return }
        let worked = worksInFrontApp
        frontApp = app
        if worksInFrontApp != worked { synchronize() }
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

    /// Adds a binding at the end of the list and returns its id. A problem shows up in `statuses`.
    @discardableResult
    public func add(combo: HotkeyCombo, actions: [HotkeyAction]) -> UUID {
        let binding = HotkeyBinding(combo: combo, actions: actions)
        settings.bindings.append(binding)
        commit()
        return binding.id
    }

    /// Changes a binding's combination and/or actions. Unknown ids are ignored.
    public func update(_ id: UUID, combo: HotkeyCombo? = nil, actions: [HotkeyAction]? = nil) {
        guard let index = settings.bindings.firstIndex(where: { $0.id == id }) else { return }
        if let combo { settings.bindings[index].combo = combo }
        if let actions { settings.bindings[index].actions = actions.uniqued }
        commit()
    }

    public func remove(_ id: UUID) {
        settings.bindings.removeAll { $0.id == id }
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

    /// A key went down in sTools' own window: macOS handed it to the window instead of turning it into a hotkey
    /// press. When a registered hotkey has exactly this key and these modifiers, it fires as a press from macOS would
    /// (a repeat, or a press for a key already down, is ignored) and this returns true, so the window doesn't also
    /// type it. False while hotkeys are off or paused, or when no hotkey has this combination.
    @discardableResult
    public func handleKeyDown(keyCode: UInt16, modifiers: HotkeyCombo.Modifiers, isRepeat: Bool) -> Bool {
        let combo = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        // Only a live registration counts: a paused one is unregistered, so its key goes on to the field.
        guard let id = registered.first(where: { $0.value == combo })?.key else { return false }
        guard !isRepeat, keysDown[id] == nil else { return true }
        if !reachedWindow {
            reachedWindow = true
            log.info("A hotkey's key reached sTools' window: \(combo.displayString, privacy: .public)")
        }
        appKeysDown.insert(id)
        handlePress(id, tracksRelease: true)
        return true
    }

    /// A key came up in sTools' own window. Ends the press of each hotkey on this key whose press came from the
    /// window; true when there was one.
    @discardableResult
    public func handleKeyUp(keyCode: UInt16) -> Bool {
        let ids = appKeysDown.filter { registered[$0]?.keyCode == keyCode }
        for id in ids {
            appKeysDown.remove(id)
            handleRelease(id)
        }
        return !ids.isEmpty
    }

    /// sTools stopped being the active app, so the window won't see the release of a key pressed in it: ends those
    /// presses now.
    public func releaseWindowKeys() {
        for id in appKeysDown {
            handleRelease(id)
        }
        appKeysDown.removeAll()
    }

    // MARK: Internals

    private func commit() {
        store.save(settings)
        synchronize()
    }

    /// Whether the registrar reports releases. One that keeps the protocol's default `onRelease` reads nil: with it,
    /// no key is ever marked down.
    private var reportsReleases: Bool { registrar.onRelease != nil }

    /// A press counts only for a binding registered right now: nothing is while hotkeys are off or paused, and a
    /// press macOS delivered just before an unregistration is stale. A press for a key that is still down is a
    /// repeat and is ignored until its release, so a held key never looks like a double press (which cancels the
    /// timer); separate presses still count. Whether macOS repeats held hotkeys at all is to be confirmed on
    /// hardware (spec 6.1); the rule is harmless if it doesn't.
    private func handlePress(_ id: UUID, tracksRelease: Bool = false) {
        guard registered[id] != nil, let binding = settings.bindings.first(where: { $0.id == id }) else { return }
        if reportsReleases || tracksRelease {
            guard keysDown[id] == nil else { return }
            keysDown[id] = binding.actions.contains(.startTimer)
        }
        let outcome = HotkeyAction.resolve(binding.actions, toolStates: toolStates())
        var events = outcome.toolChanges.map { HotkeyEvent.setTool($0.tool, isOn: $0.isOn) }
        if outcome.togglesRecording { events.append(.toggleRecording) }
        if outcome.startsTimer { events.append(.startTimer) }
        guard !events.isEmpty else { return }
        handler(events)
    }

    /// A release counts only for a key whose press counted, and sends an event only when that press sent Start
    /// timer.
    private func handleRelease(_ id: UUID) {
        appKeysDown.remove(id)
        guard keysDown.removeValue(forKey: id) == true else { return }
        handler([.startTimerReleased])
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

        var timerReleases = 0
        for (id, combo) in registered where stepsAside(combo) || wanted[id] != combo {
            registrar.unregister(id: id)
            registered[id] = nil
            // macOS can't report this key's release any more.
            appKeysDown.remove(id)
            if keysDown.removeValue(forKey: id) == true { timerReleases += 1 }
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
        if newStatuses != statuses { statuses = newStatuses }
        for _ in 0..<timerReleases { handler([.startTimerReleased]) }
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
