import AppKit
import Observation
import STPlatform

/// Runs the introduction: the flow, its saved progress, the live statuses of the Preparations, the trial
/// checklists and the Finale's switch-offs (spec 4).
@MainActor
@Observable
public final class PrologueModel {
    public private(set) var flow: PrologueFlow
    public let animations: PrologueAnimations
    public private(set) var checklists: [PrologueTrial: Checklist] = [:]
    public private(set) var companionStatuses: [PrologueCompanion: CompanionStatus] = [:]
    /// Permissions whose Allow… was pressed and that macOS may apply only after a relaunch.
    public private(set) var relaunchOffered: Set<Permission> = []
    /// What the Finale has switched off so far, in order.
    public private(set) var finaleSwitchedOff: [PrologueTrial] = []

    @ObservationIgnored public weak var host: (any PrologueHost)?
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let finaleDelay: Duration
    @ObservationIgnored private let finaleInterval: Duration
    @ObservationIgnored private var finaleTask: Task<Void, Never>?
    @ObservationIgnored private var finalePending: [PrologueTrial] = []
    @ObservationIgnored private var companionTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var watchedCompanion: PrologueCompanion?
    /// Pages showing a permission's status; while one leaves another may already be arriving.
    @ObservationIgnored private var permissionWatchers = 0

    /// Resumes at the saved step (spec D14), or starts at `step` when given.
    public init(store: SettingsStore, host: (any PrologueHost)? = nil, startingAt step: PrologueStep? = nil,
                animations: PrologueAnimations = PrologueAnimations(),
                finaleDelay: Duration = .milliseconds(500), finaleInterval: Duration = .milliseconds(420)) {
        self.store = store
        self.host = host
        self.animations = animations
        self.finaleDelay = finaleDelay
        self.finaleInterval = finaleInterval
        flow = PrologueFlow(resumingAt: step?.rawValue ?? store.load(AppState.self).prologueStep)
        save()
    }

    isolated deinit {
        finaleTask?.cancel()
        companionTask?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// True until the introduction was finished or skipped once (first launch, or after Reset sTools).
    public static func isNeeded(in store: SettingsStore) -> Bool {
        !store.load(AppState.self).prologueCompleted
    }

    public var step: PrologueStep { flow.step }

    /// The sidebar comes back for the Finale, so its switches can be seen turning off.
    public var showsSidebar: Bool { flow.step.part == .finale }

    // MARK: Navigation

    public func next() { move { $0.next() } }
    public func skipStep() { move { $0.skipStep() } }
    public func back() { move { $0.back() } }

    public func requestSkipIntroduction() {
        animations.completeAll()
        flow.requestSkipIntroduction()
    }

    public func cancelSkipIntroduction() { flow.cancelSkipIntroduction() }

    public func confirmSkipIntroduction() {
        flow.confirmSkipIntroduction()
        if flow.isEnded { end() }
    }

    private func move(_ change: (inout PrologueFlow) -> Bool) {
        let leaving = flow.step
        guard change(&flow) else { return }
        if leaving == .youreSet { completeFinale() }
        if flow.isEnded {
            end()
        } else {
            animations.reset()
            save()
        }
    }

    private func end() {
        completeFinale()
        stopAllPolling()
        save()
        if let outcome = flow.outcome { host?.prologueDidEnd(outcome) }
    }

    private func save() {
        store.save(AppState(prologueCompleted: flow.isEnded, prologueStep: flow.isEnded ? 0 : flow.step.rawValue))
    }

    // MARK: Preparations

    /// Polls permission statuses every second and on activation while a Preparations step shows. Calls are
    /// counted, because the arriving page appears before the leaving one disappears.
    public func startPollingPermissions() {
        guard let host else { return }
        permissionWatchers += 1
        if permissionWatchers == 1 { host.permissions.beginPolling() }
    }

    public func stopPollingPermissions() {
        guard permissionWatchers > 0 else { return }
        permissionWatchers -= 1
        if permissionWatchers == 0 { host?.permissions.endPolling() }
    }

    private func stopAllPolling() {
        if permissionWatchers > 0 { host?.permissions.endPolling() }
        permissionWatchers = 0
        stopWatching(watchedCompanion)
    }

    public func status(of permission: Permission) -> PermissionStatus {
        host?.permissions.status(permission) ?? .unknown
    }

    /// Allow…: the system prompt when macOS still offers one, otherwise the exact System Settings pane; only
    /// ever on a press (spec J4).
    public func allow(_ permission: Permission) async {
        guard let center = host?.permissions else { return }
        if permission.mayNeedRelaunch { relaunchOffered.insert(permission) }
        let promptable = permission == .microphone || permission == .camera
        if promptable && center.status(permission) == .denied {
            center.openSettings(for: permission)
            return
        }
        await center.request(permission)
        if !promptable && center.status(permission) != .granted {
            center.openSettings(for: permission)
        }
    }

    public func openSettings(for permission: Permission) {
        host?.permissions.openSettings(for: permission)
    }

    public func relaunch() { host?.relaunch() }

    /// Checks a companion app now, then every second and whenever sTools becomes active, until told to stop.
    public func startWatching(_ companion: PrologueCompanion) {
        stopWatching(watchedCompanion)
        watchedCompanion = companion
        companionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(companion)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh(companion) }
            }
        }
    }

    /// Stops checking `companion`; a page leaving after the next one started watching leaves that one alone.
    public func stopWatching(_ companion: PrologueCompanion?) {
        guard let companion, companion == watchedCompanion else { return }
        watchedCompanion = nil
        companionTask?.cancel()
        companionTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    public func refresh(_ companion: PrologueCompanion) async {
        guard let host else { return }
        let status = await host.check(companion)
        if companionStatuses[companion] != status { companionStatuses[companion] = status }
    }

    public func performAction(for companion: PrologueCompanion) {
        host?.performAction(for: companion)
    }

    // MARK: Trials

    /// The trial's checklist with the current items; ticks and skips so far are kept.
    public func checklist(for trial: PrologueTrial, items: [ChecklistItem]) -> Checklist {
        var list = checklists[trial] ?? Checklist()
        list.update(items: items)
        return list
    }

    /// Ticks whatever the host now reports done. Returns the newly ticked ids.
    @discardableResult
    public func record(done ids: Set<String>, items: [ChecklistItem], for trial: PrologueTrial) -> Set<String> {
        var list = checklist(for: trial, items: items)
        let fresh = list.markDone(ids)
        if checklists[trial] != list { checklists[trial] = list }
        return fresh
    }

    public func skipItem(_ id: String, items: [ChecklistItem], in trial: PrologueTrial) {
        var list = checklist(for: trial, items: items)
        list.skip(id)
        if checklists[trial] != list { checklists[trial] = list }
    }

    // MARK: Finale

    /// Switches off, one by one, every tool switched on since the Prologue began (spec 4.2, step 14; D9).
    public func runFinale() {
        guard finaleTask == nil, let host else { return }
        finalePending = host.toolsToSwitchOff()
        guard !finalePending.isEmpty else { return }
        let (delay, interval) = (finaleDelay, finaleInterval)
        finaleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self, self.switchOffNext() else { break }
                try? await Task.sleep(for: interval)
            }
            guard !Task.isCancelled else { return }
            self?.finaleTask = nil
        }
    }

    /// Any click or key, or leaving the step: whatever is still on goes off at once.
    public func completeFinale() {
        finaleTask?.cancel()
        finaleTask = nil
        while switchOffNext() {}
    }

    public var isFinaleRunning: Bool { finaleTask != nil }

    private func switchOffNext() -> Bool {
        guard !finalePending.isEmpty else { return false }
        let tool = finalePending.removeFirst()
        host?.switchOff(tool)
        finaleSwitchedOff.append(tool)
        return true
    }
}
