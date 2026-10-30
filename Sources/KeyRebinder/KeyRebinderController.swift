import Foundation
import Observation
import STPlatform

/// Owns the Key Rebinder's state: Karabiner's status and file, the profile and scope being edited, Minecraft's
/// keybinds, the checker's findings and the key tester. Every write goes through `KarabinerConfigStore`'s
/// write-safety steps (spec 5.5.3).
@MainActor
@Observable
public final class KeyRebinderController {
    /// An edit held back because `karabiner.json` changed on disk since sTools read it: `preview` is the fresh
    /// file with the edit applied, shown before anything is written.
    public struct PendingEdit: Identifiable {
        public let id = UUID()
        public let summary: String
        public let preview: KarabinerConfig
        fileprivate let edit: @Sendable (JSONValue) throws -> JSONValue
    }

    /// What the plate draws on each key, worked out once per change rather than per key per frame.
    public struct Derived {
        public var bindings: [KarabinerEvent: EffectiveBinding] = [:]
        public var rebinds: [Rebind] = []
        public var rules: [RuleSummary] = []
        public var fnKeys: [KarabinerEvent] = []
        public var findings: [CheckerFinding] = []
        /// Keys any finding points at.
        public var flaggedKeys: Set<KarabinerEvent> = []
        /// Minecraft's actions per key the game receives.
        public var minecraftActions: [KarabinerEvent: [String]] = [:]
        /// The sTools hotkeys each physical key fires (under its primary name), in list order. Empty unless the
        /// hotkey layer shows (`showsHotkeyLayer`), hotkeys are on and a keyboard is chosen.
        public var hotkeysByKey: [KarabinerEvent: [HotkeyBinding]] = [:]
        /// Hotkeys no drawn key or button sends, in list order.
        public var unplacedHotkeys: [HotkeyBinding] = []
        /// "Hotkey takes a game key" findings, kept apart from the rule findings so the trial can leave them out.
        public var hotkeyFindings: [CheckerFinding] = []
        /// Keys a hotkey finding points at, under every name.
        public var hotkeyFlaggedKeys: Set<KarabinerEvent> = []
    }

    public var settings: KeyRebinderSettings {
        didSet {
            guard settings != oldValue else { return }
            services.settings.save(settings)
            if settings.backupsKept != oldValue.backupsKept { rebuildStore() }
            if settings.customOptionsFilePath != oldValue.customOptionsFilePath || settings.showsMinecraftKeybinds != oldValue.showsMinecraftKeybinds {
                loadMinecraftKeybinds()
            }
            recompute()
        }
    }

    public private(set) var requirement: KarabinerRequirement?
    public private(set) var karabinerVersion: String?
    public private(set) var config: KarabinerConfig?
    /// Why the file could not be read, when it couldn't.
    public private(set) var configProblem: String?
    public private(set) var configIsSymbolicLink = false
    public private(set) var profileNames: [String] = []
    public private(set) var currentProfile: String?
    public private(set) var devices: [ConnectedDevice] = []
    /// nil when no `options.txt` could be read (or the setting is off).
    public private(set) var minecraftKeybinds: [MinecraftKeybind]?
    public private(set) var optionsFile: URL?
    public private(set) var optionsProblem: String?
    public private(set) var pendingEdit: PendingEdit?
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false
    public private(set) var derived = Derived()

    public var selectedKey: KarabinerEvent?

    /// True once `karabiner.json` has been read, including while its parsed tree is let go of between visits to the
    /// page (`releaseLoadedFile()`); the page draws from `derived` in the meantime, as it does with the tree.
    public var hasLoadedConfig: Bool { config != nil || configIsLetGo }
    /// The parsed file was let go when the page closed, and `derived` still describes it.
    @ObservationIgnored private var configIsLetGo = false
    /// Counts the times the file was let go, so a read that finishes after one doesn't bring the tree back.
    @ObservationIgnored private var releaseCount = 0

    /// The app's hotkey list, once `connect(hotkeys:)` has run. The Key Rebinder shows and edits it on the keys
    /// (spec 5.5.2, 5.5.3) and advises on it (`HotkeyAdvising`).
    public internal(set) var hotkeyCenter: HotkeyCenter?

    // Live key tester (spec 5.5.5).
    public var isTesting = false {
        didSet {
            if !isTesting { litKeys = []; lastTrace = nil }
            updateHotkeyPause()
        }
    }
    public private(set) var litKeys: Set<KarabinerEvent> = []
    public private(set) var lastTrace: KeyTester.Trace?

    /// While true, the next key (or mouse button 3 and up) pressed becomes `capturedOutput` instead of
    /// selecting a key; buttons 1 and 2 stay free for clicking.
    public var isCapturingOutput = false {
        didSet { updateHotkeyPause() }
    }
    public var capturedOutput: KarabinerEvent?

    /// sTools hotkeys pause while the page listens for raw keys (Test keys, or choosing an output by pressing it), so
    /// those see every key (spec 5.5.3, 5.5.5, 6.1). Selecting a key by pressing it doesn't pause them.
    func updateHotkeyPause() {
        hotkeyCenter?.setPaused(isTesting || isCapturingOutput, for: .keyRebinder)
    }

    @ObservationIgnored let services: ToolServices
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let backupsDirectory: URL
    @ObservationIgnored private let cli: KarabinerCLI
    @ObservationIgnored private let probes: KarabinerProbes
    @ObservationIgnored private var store: KarabinerConfigStore
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    public convenience init(services: ToolServices) {
        let cli = KarabinerCLI(runner: ProcessCommandRunner())
        self.init(
            services: services, configURL: KarabinerConfigStore.defaultConfigURL(),
            backupsDirectory: KarabinerConfigStore.defaultBackupsDirectory(), cli: cli, probes: .live(cli: cli))
    }

    public init(services: ToolServices, configURL: URL, backupsDirectory: URL, cli: KarabinerCLI, probes: KarabinerProbes) {
        self.services = services
        self.configURL = configURL
        self.backupsDirectory = backupsDirectory
        self.cli = cli
        self.probes = probes
        let loaded = services.settings.load(KeyRebinderSettings.self)
        settings = loaded
        store = KarabinerConfigStore(configURL: configURL, backupsDirectory: backupsDirectory, backupsKept: loaded.backupsKept)
        watchMinecraft()
    }

    // MARK: Derived values

    public var layout: KeyboardLayout? { settings.layout }

    /// Editing and profiles need Karabiner fully ready and a writable file (spec 5.5.7).
    public var canEdit: Bool {
        requirement == .ready && hasLoadedConfig && currentProfile != nil && !configIsSymbolicLink
    }

    /// Every key and button the user has: the chosen keyboard plus mouse buttons 1–8.
    public var physicalKeys: [KarabinerEvent] {
        (layout?.keys.map(\.event) ?? []) + MouseLayout.buttons.map(\.event)
    }

    /// The `from` to write for a key: the name an existing rebind already uses for it (`left_alt` for the Option
    /// key), so editing replaces that entry instead of adding a second one under another name.
    public func source(for key: KarabinerEvent) -> KarabinerEvent {
        let aliases = KeyTable.shared.aliases(of: key)
        return derived.rebinds.first { aliases.contains($0.from) }?.from ?? key
    }

    /// The binding drawn on `key`, found under any of its names.
    public func binding(for key: KarabinerEvent) -> EffectiveBinding? {
        KeyTable.shared.aliases(of: key).lazy.compactMap { self.derived.bindings[$0] }.first
    }

    /// Findings that point at `key`.
    public func findings(for key: KarabinerEvent) -> [CheckerFinding] {
        let aliases = Set(KeyTable.shared.aliases(of: key))
        return derived.findings.filter { !aliases.isDisjoint(with: $0.keys) }
    }

    /// Hotkey findings that point at `key`.
    public func hotkeyFindings(for key: KarabinerEvent) -> [CheckerFinding] {
        let aliases = Set(KeyTable.shared.aliases(of: key))
        return derived.hotkeyFindings.filter { !aliases.isDisjoint(with: $0.keys) }
    }

    /// Works out `derived` again. Internal so the hotkey extension can run it when the hotkey list changes.
    func recompute() {
        // While the file is let go there is nothing to work its parts out from: they stay as they were, and the rest
        // (Minecraft's actions, the hotkey layer) is worked out again around them.
        var next = configIsLetGo ? derived : Derived()
        if configIsLetGo {
            next.minecraftActions = [:]
            next.hotkeysByKey = [:]
            next.unplacedHotkeys = []
            next.hotkeyFindings = []
            next.hotkeyFlaggedKeys = []
        }
        // The hotkeys macOS accepted, while hotkeys are on: they consume their keys.
        let activeHotkeys = hotkeysAreOn ? hotkeyCenter?.activeBindings ?? [] : []
        // While an edit waits for confirmation, the plate shows the file as it would be after saving.
        if let config = pendingEdit?.preview ?? config, let profile = currentProfile {
            let scope = settings.scope
            next.bindings = EffectiveMapping.bindings(in: config.root, profile: profile, scope: scope)
            next.rebinds = RebindEditor.rebinds(in: config.root, profile: profile, scope: scope)
            next.rules = RebindEditor.rules(in: config.root, profile: profile)
            next.fnKeys = RebindEditor.fnFunctionKeys(in: config.root, profile: profile, scope: scope)
            if settings.checkerEnabled {
                let context = RuleChecker.Context(
                    physicalKeys: physicalKeys, minecraftKeybinds: minecraftKeybinds,
                    includesSpeedrunRules: settings.checkerIncludesSpeedrunRules, hotkeys: activeHotkeys)
                next.findings = RuleChecker.findings(in: config.root, profile: profile, scope: scope, context: context)
                next.flaggedKeys = Set(next.findings.flatMap(\.keys).flatMap(KeyTable.shared.aliases(of:)))
            }
        }
        for keybind in minecraftKeybinds ?? [] {
            guard let event = keybind.event else { continue }
            next.minecraftActions[KeyTable.shared.canonical(event), default: []].append(keybind.display)
        }
        // Hotkeys on keys work with or without karabiner.json: without one, every key sends itself.
        if showsHotkeyLayer, hotkeysAreOn, layout != nil, let center = hotkeyCenter {
            let index = HotkeyKeys.index(center.bindings, physicalKeys: physicalKeys, bindings: next.bindings)
            next.hotkeysByKey = index.byKey
            next.unplacedHotkeys = index.unplaced
            if settings.checkerEnabled {
                next.hotkeyFindings = RuleChecker.hotkeyFindings(
                    physicalKeys: physicalKeys, bindings: next.bindings, hotkeys: activeHotkeys, minecraftKeybinds: minecraftKeybinds)
                next.hotkeyFlaggedKeys = Set(next.hotkeyFindings.flatMap(\.keys).flatMap(KeyTable.shared.aliases(of:)))
            }
        }
        derived = next
    }

    /// Minecraft's actions on the key the game receives as `event`.
    public func minecraftActions(for event: KarabinerEvent) -> [String] {
        derived.minecraftActions[KeyTable.shared.canonical(event)] ?? []
    }

    // MARK: Status and loading

    /// Re-checks Karabiner, reloads the file, profiles, devices and Minecraft's keybinds.
    public func refresh() async {
        requirement = await KarabinerStatus(probes: probes).evaluate()
        karabinerVersion = requirement == .ready ? try? await cli.version() : nil
        configIsSymbolicLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: configURL.path)) != nil
        await reloadConfig()
        if requirement == .ready {
            if let names = try? await cli.listProfileNames() { profileNames = names }
            if let current = try? await cli.currentProfileName(), profileNames.contains(current) { currentProfile = current }
            devices = (try? await cli.listConnectedDevices()) ?? []
        } else {
            devices = []
        }
        loadMinecraftKeybinds()
        recompute()
    }

    /// Reads `karabiner.json` again (profiles from the file; the CLI's answer wins in `refresh`).
    public func reloadConfig() async {
        guard pendingEdit == nil else { return }
        let released = releaseCount
        do {
            let loaded = try await store.load()
            // The page closed while the file was being read: the tree isn't kept, and the next visit reads it again.
            guard released == releaseCount else { return }
            apply(loadedConfig: loaded)
            configProblem = nil
        } catch {
            guard released == releaseCount else { return }
            config = nil
            configIsLetGo = false
            profileNames = []
            currentProfile = nil
            configProblem = error.localizedDescription
        }
        recompute()
    }

    /// Lets go of the parsed `karabiner.json` when the page closes. The controller lives as long as the app, and the
    /// tree costs about four times the file's size in memory (several MB for a file with many rules). What the keys and
    /// the page's sections show is in `derived` and the profile names, which stay, so the page comes back the way it
    /// was and reads the file again as it does on every visit. Nothing is let go while an edit waits for confirmation:
    /// its preview and the file are what the page is showing.
    public func releaseLoadedFile() {
        releaseCount += 1
        guard pendingEdit == nil, config != nil else { return }
        config = nil
        configIsLetGo = true
    }

    private func apply(loadedConfig loaded: KarabinerConfig) {
        config = loaded
        configIsLetGo = false
        profileNames = loaded.profiles.map(\.name)
        // Without Karabiner running there is no CLI answer, so the file's selected profile is the current one.
        if requirement != .ready || !profileNames.contains(currentProfile ?? "") {
            currentProfile = loaded.selectedProfileName
        }
    }

    /// Reloads when Karabiner (or anything else) rewrites its file while the page is showing.
    public func startWatching() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(directory: configURL.deletingLastPathComponent()) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    public func stopWatching() {
        watcher = nil
        reloadTask?.cancel()
    }

    /// Karabiner's save is several file operations; reload once they settle.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reloadConfig()
        }
    }

    private func rebuildStore() {
        store = KarabinerConfigStore(configURL: configURL, backupsDirectory: backupsDirectory, backupsKept: settings.backupsKept)
        Task { await reloadConfig() }
    }

    // MARK: Minecraft keybinds

    private func watchMinecraft() {
        withObservationTracking {
            _ = services.minecraft.active?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadMinecraftKeybinds()
                self?.recompute()
                self?.watchMinecraft()
            }
        }
    }

    /// Reads `options.txt`: the chosen file, else the running Minecraft's, else the last one found.
    public func loadMinecraftKeybinds() {
        guard settings.showsMinecraftKeybinds else {
            minecraftKeybinds = nil
            optionsFile = nil
            optionsProblem = nil
            return
        }
        let file: URL?
        if let custom = settings.customOptionsFilePath {
            file = URL(fileURLWithPath: custom)
        } else if let pid = services.minecraft.active?.window.processID,
                  let directory = MinecraftGameDirectory.find(processID: pid),
                  let found = MinecraftKeybinds.locateOptionsFile(gameDirectory: directory) {
            file = found
            if settings.lastFoundOptionsFilePath != found.path { settings.lastFoundOptionsFilePath = found.path }
        } else {
            file = settings.lastFoundOptionsFilePath.map { URL(fileURLWithPath: $0) }
        }
        guard let file else {
            minecraftKeybinds = nil
            optionsFile = nil
            optionsProblem = "Open Minecraft once so sTools can find its keybinds, or choose its options.txt."
            return
        }
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            minecraftKeybinds = nil
            optionsFile = file
            optionsProblem = "sTools could not read \(file.path)."
            return
        }
        minecraftKeybinds = MinecraftKeybinds.parse(optionsText: text)
        optionsFile = file
        optionsProblem = nil
    }

    // MARK: Editing

    private func perform(_ summary: String, _ edit: @escaping @Sendable (JSONValue) throws -> JSONValue) async {
        guard canEdit else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            handle(try await store.apply(edit), summary: summary, edit: edit)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handle(_ result: ApplyResult, summary: String, edit: @escaping @Sendable (JSONValue) throws -> JSONValue) {
        switch result {
        case .written(let written, _), .unchanged(let written):
            pendingEdit = nil
            apply(loadedConfig: written)
            recompute()
        case .changedExternally(let preview):
            pendingEdit = PendingEdit(summary: summary, preview: preview, edit: edit)
            recompute()
        }
    }

    /// Writes the held-back edit onto the changed file, exactly as previewed.
    public func confirmPendingEdit() async {
        guard let pending = pendingEdit else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            handle(try await store.apply(confirm: true, pending.edit), summary: pending.summary, edit: pending.edit)
            errorMessage = nil
        } catch {
            pendingEdit = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Drops the held-back edit and shows the file as it is now.
    public func discardPendingEdit() async {
        pendingEdit = nil
        await reloadConfig()
    }

    public func dismissError() { errorMessage = nil }

    public func setRebind(_ key: KarabinerEvent, to output: KarabinerEvent) async {
        guard let profile = currentProfile else { return }
        let from = source(for: key)
        let scope = settings.scope
        await perform("\(KeyNames.name(for: key)) \u{2192} \(KeyNames.name(for: output))") {
            try RebindEditor.setRebind(in: $0, profile: profile, from: from, to: output, scope: scope)
        }
    }

    public func removeRebind(_ key: KarabinerEvent) async {
        guard let profile = currentProfile else { return }
        let from = source(for: key)
        let scope = settings.scope
        await perform("Remove the rebind on \(KeyNames.name(for: key))") {
            try RebindEditor.removeRebind(in: $0, profile: profile, from: from, scope: scope)
        }
    }

    public func setFnKey(_ number: Int, to output: KarabinerEvent?) async {
        guard let profile = currentProfile else { return }
        let scope = settings.scope
        await perform("F\(number) without fn") {
            try RebindEditor.setFnFunctionKey(number, to: output, in: $0, profile: profile, scope: scope)
        }
    }

    // MARK: Complex rules

    public func setRuleOutput(rule: Int, manipulator: Int, to output: KarabinerEvent) async {
        guard let profile = currentProfile else { return }
        await perform("Change a rule") {
            try RebindEditor.setManipulatorOutput(in: $0, profile: profile, rule: rule, manipulator: manipulator, to: output)
        }
    }

    public func setRuleEnabled(_ index: Int, enabled: Bool) async {
        guard let profile = currentProfile else { return }
        await perform(enabled ? "Turn a rule on" : "Turn a rule off") {
            try RebindEditor.setRuleEnabled(in: $0, profile: profile, at: index, enabled: enabled)
        }
    }

    public func deleteRule(_ index: Int) async {
        guard let profile = currentProfile else { return }
        await perform("Delete a rule") { try RebindEditor.deleteRule(in: $0, profile: profile, at: index) }
    }

    public func moveRule(from source: Int, to destination: Int) async {
        guard let profile = currentProfile else { return }
        await perform("Reorder rules") { try RebindEditor.moveRule(in: $0, profile: profile, from: source, to: destination) }
    }

    public func rule(at index: Int) -> JSONValue? {
        guard let config, let profile = currentProfile else { return nil }
        return RebindEditor.rule(in: config.root, profile: profile, at: index)
    }

    public func ruleText(_ index: Int) -> String? {
        rule(at: index)?.serialized()
    }

    public enum LintOutcome: Equatable, Sendable {
        case valid(JSONValue)
        case invalid([String])
    }

    /// Checks edited rule JSON: it must parse as one object, then pass `karabiner_cli --lint-complex-modifications`.
    public func lint(ruleText text: String) async -> LintOutcome {
        let rule: JSONValue
        do {
            rule = try JSONValue.parse(text)
        } catch {
            return .invalid(["This is not valid JSON: \(error)"])
        }
        guard rule.isObject else { return .invalid(["A rule is one JSON object: { \"description\": …, \"manipulators\": [ … ] }."]) }
        let file = FileManager.default.temporaryDirectory.appending(path: "sTools-lint-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try Data(RebindEditor.lintDocument(for: rule).serialized().utf8).write(to: file)
            switch try await cli.lintComplexModifications(path: file) {
            case .valid: return .valid(rule)
            case .invalid(let messages): return .invalid(messages)
            }
        } catch {
            return .invalid([error.localizedDescription])
        }
    }

    /// Saves JSON already passed through `lint`.
    public func replaceRule(_ index: Int, with rule: JSONValue) async {
        guard let profile = currentProfile else { return }
        await perform("Edit a rule") { try RebindEditor.replaceRule(in: $0, profile: profile, at: index, with: rule) }
    }

    // MARK: Profiles (spec 5.5.6)

    public func selectProfile(_ name: String) async {
        guard canEdit, name != currentProfile else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await cli.selectProfile(name)
            currentProfile = name
            selectedKey = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadConfig()
    }

    public func createProfile(named name: String, duplicatingCurrent: Bool) async {
        guard let current = currentProfile else { return }
        await perform("New profile \u{201C}\(name)\u{201D}") { config in
            duplicatingCurrent
                ? try RebindEditor.duplicateProfile(in: config, name: current, as: name)
                : try RebindEditor.createEmptyProfile(in: config, name: name)
        }
    }

    public func renameProfile(_ name: String, to newName: String) async {
        // Reading the written file back can't tell which profile was current once its name changed, so the
        // answer is carried across the write.
        let wasCurrent = currentProfile == name
        await perform("Rename \u{201C}\(name)\u{201D}") { try RebindEditor.renameProfile(in: $0, name: name, to: newName) }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if wasCurrent, pendingEdit == nil, profileNames.contains(trimmed) {
            currentProfile = trimmed
            recompute()
        }
    }

    public func duplicateProfile(_ name: String, as newName: String) async {
        await perform("Duplicate \u{201C}\(name)\u{201D}") { try RebindEditor.duplicateProfile(in: $0, name: name, as: newName) }
    }

    public func deleteProfile(_ name: String) async {
        await perform("Delete \u{201C}\(name)\u{201D}") { try RebindEditor.deleteProfile(in: $0, name: name) }
    }

    public func moveProfile(from source: Int, to destination: Int) async {
        await perform("Reorder profiles") { try RebindEditor.moveProfile(in: $0, from: source, to: destination) }
    }

    /// The name offered for a new profile: "Untitled Profile", then "Untitled Profile 2"… (answer I17).
    public func suggestedNewProfileName() -> String {
        config.map { RebindEditor.uniqueProfileName("Untitled Profile", in: $0.root) } ?? "Untitled Profile"
    }

    public func suggestedCopyName(of name: String) -> String {
        config.map { RebindEditor.suggestedCopyName(of: name, in: $0.root) } ?? "\(name) (copy)"
    }

    // MARK: Key tester and key presses

    /// The physical key a pressed event most likely came from: its one source when the rebinds name exactly
    /// one, else the event itself. Used to pick a key or an output by pressing it.
    public func physicalKey(forArrived event: KarabinerEvent) -> KarabinerEvent {
        let trace = KeyTester.trace(event, physicalKeys: physicalKeys, bindings: derived.bindings)
        return trace.sources.count == 1 ? trace.sources[0] : event
    }

    public func testerPressed(_ event: KarabinerEvent) {
        guard isTesting else { return }
        litKeys.insert(event)
        // Hotkeys pause while Test keys is on, which is why their keys can arrive here at all.
        let hotkeys = showsHotkeyLayer && hotkeysAreOn ? hotkeyCenter?.activeBindings ?? [] : []
        lastTrace = KeyTester.trace(
            event, physicalKeys: physicalKeys, bindings: derived.bindings, minecraftKeybinds: minecraftKeybinds,
            hotkeys: hotkeys, hotkeysPaused: hotkeyCenter?.isPaused ?? false)
    }

    public func testerReleased(_ event: KarabinerEvent) {
        litKeys.remove(event)
    }

    /// Asked about each key before the page uses it: true when the app around the page has a use for that key right
    /// now, so the page leaves it alone (the tester still lights it) and the window gets it. The introduction's trial
    /// takes Return this way while its Continue is enabled, as Return presses Continue on every other step
    /// (spec 4.1). Nil everywhere else.
    @ObservationIgnored public var hostTakesKey: (@MainActor (KarabinerEvent) -> Bool)?

    /// Routes a press from sTools' window: the tester first, then output capture, then selecting the pressed
    /// key on the diagram. `isBusy` is true while a text field or sheet has the keyboard, and a key the host takes
    /// (`hostTakesKey`) counts as one too. Returns true when the press was used, so the window doesn't also beep at it.
    func handle(_ press: KeyPress, commandHeld: Bool, isBusy: Bool) -> Bool {
        let isBusy = isBusy || hostTakesKey?(press.event) == true
        let isKey = if case .key = press.event { true } else { false }
        if isTesting {
            switch press {
            case .down(let event, let isRepeat): if !isRepeat { testerPressed(event) }
            case .up(let event): testerReleased(event)
            }
            return isKey && !commandHeld && !isBusy
        }
        guard case .down(let event, isRepeat: false) = press, !commandHeld, !isBusy else { return false }
        if isCapturingOutput {
            guard isKey || (MouseLayout.buttonNumber(of: event) ?? 0) >= 3 else { return false }
            capturedOutput = physicalKey(forArrived: event)
            isCapturingOutput = false
            return true
        }
        guard isKey, let layout else { return false }
        let physical = KeyTable.shared.canonical(physicalKey(forArrived: event))
        guard let key = layout.keys.first(where: { KeyTable.shared.canonical($0.event) == physical }) else { return false }
        selectedKey = key.event
        return true
    }

    // MARK: Layout, scope and reset

    public func chooseLayout(shape: KeyboardShape, formFactor: KeyboardFormFactor) {
        settings.keyboardShape = shape
        settings.formFactor = formFactor
    }

    public func setScope(_ device: DeviceIdentifiers?) {
        settings.scopeDevice = device
        selectedKey = nil
    }

    public func resetToDefault() {
        settings = KeyRebinderSettings.defaultValue
    }

    /// One line for Help ▸ Copy Diagnostics.
    public var diagnosticsSummary: String {
        switch requirement {
        case nil: "Not checked yet"
        case .ready?: "Ready" + (karabinerVersion.map { ", Karabiner-Elements \($0)" } ?? "")
        case .notInstalled?: "Karabiner-Elements not installed"
        case .notRunning?: "Karabiner-Elements not running"
        case .versionTooOld(let found)?: "Karabiner-Elements \(found) is too old (needs 16.0)"
        case .configUnreadable?: "karabiner.json missing or unreadable"
        }
    }
}
