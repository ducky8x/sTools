import Foundation
import Observation

/// What the app should do when a hotkey fires.
public enum HotkeyEvent: Equatable, Sendable {
    /// Switch a tool to a state (the controller must tolerate being told its current state).
    case setTool(HotkeyTool, isOn: Bool)
    /// Start recording if idle, stop if recording.
    case toggleRecording
}

/// Why a binding is not active.
public enum HotkeyConflict: Equatable, Sendable {
    /// An earlier binding in the list already uses this combination.
    case alreadyUsedByYou(UUID)
    /// The system refused the registration (another app or macOS owns the combination).
    case systemRefused
    /// The combination itself cannot be a hotkey (unmodified letter, reserved by macOS, ...).
    case invalidCombo(HotkeyComboIssue)
    /// The binding has no actions.
    case noActions
}

/// The state of one binding.
public enum HotkeyStatus: Equatable, Sendable {
    /// Registered with the system and listening.
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
@MainActor
@Observable
public final class HotkeyCenter {
    public private(set) var settings: HotkeySettings
    public private(set) var statuses: [UUID: HotkeyStatus] = [:]

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let registrar: any HotkeyRegistering
    @ObservationIgnored private let toolStates: @MainActor () -> [HotkeyTool: Bool]
    @ObservationIgnored private let handler: @MainActor ([HotkeyEvent]) -> Void
    @ObservationIgnored private var registered: [UUID: HotkeyCombo] = [:]
    @ObservationIgnored private let log = STLog.logger("Hotkeys")

    /// - Parameters:
    ///   - toolStates: Reports which switchable tools are on right now. Read on every press.
    ///   - handler: Receives each press's events together, in order: one per tool change, then one for
    ///     recording. One call per press, so the app can confirm the press once.
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

    public func status(of id: UUID) -> HotkeyStatus? { statuses[id] }

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
        guard settings.isEnabled, let binding = settings.bindings.first(where: { $0.id == id }) else { return }
        let outcome = HotkeyAction.resolve(binding.actions, toolStates: toolStates())
        var events = outcome.toolChanges.map { HotkeyEvent.setTool($0.tool, isOn: $0.isOn) }
        if outcome.togglesRecording { events.append(.toggleRecording) }
        guard !events.isEmpty else { return }
        handler(events)
    }

    /// Brings registrations and statuses in line with the settings: unregisters what is no longer wanted,
    /// registers what is new or changed, leaves unchanged registrations alone.
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

        for (id, combo) in registered where wanted[id] != combo {
            registrar.unregister(id: id)
            registered[id] = nil
        }
        for binding in settings.bindings {
            guard let combo = wanted[binding.id] else { continue }
            if registered[binding.id] == combo {
                newStatuses[binding.id] = .registered
                continue
            }
            do {
                try registrar.register(combo, id: binding.id)
                registered[binding.id] = combo
                newStatuses[binding.id] = .registered
            } catch {
                log.error("System refused \(combo.displayString, privacy: .public): \(String(describing: error), privacy: .public)")
                newStatuses[binding.id] = .conflict(.systemRefused)
            }
        }
        statuses = newStatuses
    }
}
