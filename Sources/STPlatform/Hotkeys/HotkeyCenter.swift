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

/// The state of one binding.
public enum HotkeyStatus: Equatable, Sendable {
    /// Accepted by macOS, and live whenever sTools isn't in front. While hotkeys pause (sTools is the active app)
    /// nothing is registered, but the status stays, so switching apps never changes it.
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
/// Hotkeys pause while sTools is the active app (`isPaused`, Advanced setting on by default), so every key works
/// in sTools itself: typing, recording a combination, testing keys. While paused nothing is registered and presses
/// are ignored; a combination macOS hasn't accepted yet this run is still tried once (registered and released at
/// once), so a refusal shows the moment a hotkey is added. When the pause ends everything registers for real.
@MainActor
@Observable
public final class HotkeyCenter {
    public private(set) var settings: HotkeySettings
    /// Assigned only when a status really changes, so app switches don't re-render the pages that show them.
    public private(set) var statuses: [UUID: HotkeyStatus] = [:]

    /// Whether sTools is the active app. Only the app delegate sets it (and only it knows), so a center nobody
    /// tells about activity (tests, previews) never pauses, and a pause can't outlast sTools being in front.
    @ObservationIgnored public var appIsActive = false {
        didSet { if appIsActive != oldValue { synchronize() } }
    }

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
    @ObservationIgnored private let log = STLog.logger("Hotkeys")

    /// - Parameters:
    ///   - toolStates: Reports which switchable tools are on right now. Read on every press.
    ///   - handler: Receives each press's events together, in order: one per tool change, then one for
    ///     recording, then one for Start timer. One call per press, so the app can confirm the press once.
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

    /// Advanced: whether hotkeys pause while sTools is the active app. On by default. Off, hotkeys also fire in
    /// sTools, which then can't record, test or type their keys.
    public var pausesWhileSToolsIsActive: Bool {
        get { settings.pausesWhileSToolsIsActive }
        set {
            guard newValue != settings.pausesWhileSToolsIsActive else { return }
            settings.pausesWhileSToolsIsActive = newValue
            commit()
        }
    }

    /// Hotkeys are on but paused, because sTools is in front and the pause setting is on.
    public var isPaused: Bool { settings.isEnabled && settings.pausesWhileSToolsIsActive && appIsActive }

    /// While the master switch is on, the bindings that take their key from other apps: valid, the first owner of
    /// their combination, with actions, and accepted by macOS (live, or paused while sTools is in front). A binding
    /// macOS refused takes nothing, so it isn't here. Empty while the switch is off.
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
        if let typing = HotkeyWording.typingNote(for: combo) { notes.append(HotkeyNote(tone: .note, text: typing)) }
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

    // MARK: Internals

    private func commit() {
        store.save(settings)
        synchronize()
    }

    private func handlePress(_ id: UUID) {
        guard settings.isEnabled, !isPaused, let binding = settings.bindings.first(where: { $0.id == id }) else { return }
        let outcome = HotkeyAction.resolve(binding.actions, toolStates: toolStates())
        var events = outcome.toolChanges.map { HotkeyEvent.setTool($0.tool, isOn: $0.isOn) }
        if outcome.togglesRecording { events.append(.toggleRecording) }
        if outcome.startsTimer { events.append(.startTimer) }
        guard !events.isEmpty else { return }
        handler(events)
    }

    /// Brings registrations and statuses in line with the settings: unregisters what is no longer wanted,
    /// registers what is new or changed, leaves unchanged registrations alone. While paused it unregisters
    /// everything and only tries combinations macOS hasn't accepted yet.
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

        let paused = isPaused
        for (id, combo) in registered where paused || wanted[id] != combo {
            registrar.unregister(id: id)
            registered[id] = nil
        }
        for binding in settings.bindings {
            guard let combo = wanted[binding.id] else { continue }
            if paused {
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
    }

    /// While paused: a combination macOS accepted before is fine; anything else is registered and released in
    /// the same turn, so a refusal still shows at once.
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
