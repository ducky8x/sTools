import AppKit
import Backdrop
import Crosshair
import KeyRebinder
import NBBOverlay
import Observation
import Prologue
import ScreenRecording
import STPlatform
import SwiftUI
import TimerOverlay

/// What the trials remember while the introduction runs: where each tool started, so an item ticks when the
/// user changes it, and what was seen happen along the way.
@MainActor
@Observable
final class TrialSession {
    var crosshairStart: CrosshairSettings?
    var timerStartOffset: [Int]?
    /// A Test run is under way; when it leaves, `timerTestLeft` ticks its item.
    @ObservationIgnored var timerTestRunning = false
    var timerTestLeft = false
    /// The Start-timer keys when the trial began, by hotkey.
    var timerKeysAtStart: [UUID: HotkeyCombo]?
    var backdropStartFill: BackdropSettings.Fill?
    var nbbStartOffset: [Int]?
    @ObservationIgnored var nbbFirstResult: NBBEvents.Stronghold?
    var nbbSawUpdate = false
    var recordingStartSources: [VideoSource]?
    var recordingBaselineTaken = false
    var recordingSavedAtStart: RecordingFinisher.SaveResult?
    var isRecordingTest = false
    var didPlayBack = false
    var testedKeys: Set<KarabinerEvent> = []
    var openedProfileMenu = false
    @ObservationIgnored var rebindsAtStart: Set<Rebind>?
    @ObservationIgnored var madeRebind = false
    var madeAndRemovedRebind = false

    @ObservationIgnored private var watchers: [PrologueTrial: [ObservationLoop]] = [:]
    @ObservationIgnored private var menuObserver: NSObjectProtocol?

    /// Runs `body` now and again whenever an observable value it read changes, until that trial stops watching.
    func watch(for trial: PrologueTrial, _ body: @escaping @MainActor () -> Void) {
        watchers[trial, default: []].append(ObservationLoop(body))
    }

    /// The Key Rebinder's profile menu is an ordinary menu; it counts as opened when it starts tracking.
    func watchProfileMenu() {
        guard menuObserver == nil else { return }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            let isProfileMenu = (note.object as? NSMenu)?.items.contains { $0.title == TrialCopy.manageProfilesItem } ?? false
            MainActor.assumeIsolated {
                if isProfileMenu { self?.openedProfileMenu = true }
            }
        }
    }

    /// Stops one trial's watching (a page leaving must not stop the arriving one's), or everything.
    func stopWatching(_ trial: PrologueTrial? = nil) {
        for (key, loops) in watchers where trial == nil || key == trial {
            for loop in loops { loop.cancel() }
            watchers[key] = nil
        }
        if trial == nil || trial == .keyRebinder {
            if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
            menuObserver = nil
        }
    }
}

/// Re-runs a closure each time the observable state it reads changes.
@MainActor
final class ObservationLoop {
    private var isActive = true
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func cancel() { isActive = false }

    private func run() {
        guard isActive else { return }
        withObservationTracking(body) { [weak self] in
            Task { @MainActor in self?.run() }
        }
    }
}

/// The trials' checklist wording (spec 4.2), gathered here.
enum TrialCopy {
    static let needsAccessibility = "Needs Accessibility (step 2)."
    static let needsScreenRecording = "Needs Screen & System Audio Recording (step 3)."
    static let needsKarabiner = "Needs Karabiner-Elements (step 8)."
    static let manageProfilesItem = "Manage Profiles\u{2026}"

    enum Crosshair {
        static let on = "Switch it on and find it"
        static let onDetail = "It sits at the center of the screen Minecraft is on, or of your main screen."
        static let shape = "Try another shape"
        static let color = "Change its color"
        static let offset = "Nudge it with an offset"
        static let image = "Use your own image"
    }

    enum Timer {
        static let on = "Switch it on"
        static let test = "Press Test and watch it run"
        static let testDetail = "A 5-second run pops up, counts down, rings and leaves. Your saved duration stays as it is."
        static let place = "Drag it into place and see the rule guides"
        static let placeDetail = "Turn on \u{201C}Move by dragging\u{201D}, then drag the timer."
        static let key = "Set a Start-timer key"
        static let keyDetail = "It\u{2019}s saved as a hotkey in Home \u{25B8} Hotkeys."
    }

    enum Backdrop {
        static let on = "Switch it on"
        static let onWithMinecraft = "It covers the screen behind Minecraft."
        static let onWithoutMinecraft = "Minecraft isn\u{2019}t open, so it sits right behind this window instead."
        static let fill = "Change the fill"
    }

    enum NBB {
        static let on = "Switch it on"
        static let place = "Drag it into place and feel it snap"
        static let placeDetail = "Turn on \u{201C}Move and resize by dragging\u{201D}, then drag the overlay."
        static let measure = "Measure an eye and watch it update"
        static let measureDetail = "Throw an ender eye and measure it in Ninjabrain Bot."
        static let sample = "Ninjabrain Bot isn\u{2019}t connected, so the overlay shows a sample result."
    }

    enum Recording {
        static let source = "Add a source and place it"
        static let sourceDetail = "Use Add Source under the canvas, then drag it into place."
        static let record = "Record a 5-second test"
        static let recordDetail = "The clip is saved like any recording."
        static let play = "Play it back here"
    }

    enum KeyRebinder {
        static let layout = "Pick your keyboard layout"
        static let find = "Find your rebinds and Minecraft keybinds on the diagram"
        static let findDetail = "Select a key to see what it does."
        static let tester = "Press a few keys in the live key tester"
        static let testerDetail = "Turn on Test keys on the plate, then press away."
        static let profiles = "Open the profile menu"
        static let rebind = "Make a rebind, then remove it"
    }
}

extension AppModel {
    func trialContent(_ trial: PrologueTrial) -> TrialContent {
        switch trial {
        case .crosshair: crosshairTrial()
        case .timerOverlay: timerTrial()
        case .windowBackdrop: backdropTrial()
        case .nbbOverlay: nbbTrial()
        case .screenRecording: recordingTrial()
        case .keyRebinder: keyRebinderTrial()
        }
    }

    private static let emptyTrial = TrialContent(items: { [] }, completed: { [] }, controls: { AnyView(EmptyView()) })

    private func needsAccessibility() -> String? {
        accessibilityGranted ? nil : TrialCopy.needsAccessibility
    }

    private func crosshairTrial() -> TrialContent {
        guard let crosshair = controller(for: .crosshair, as: CrosshairController.self) else { return Self.emptyTrial }
        let session = trials
        return TrialContent(
            items: { [
                ChecklistItem(id: "on", title: TrialCopy.Crosshair.on, detail: TrialCopy.Crosshair.onDetail,
                              unavailableReason: self.needsAccessibility()),
                ChecklistItem(id: "shape", title: TrialCopy.Crosshair.shape),
                ChecklistItem(id: "color", title: TrialCopy.Crosshair.color),
                ChecklistItem(id: "offset", title: TrialCopy.Crosshair.offset),
                ChecklistItem(id: "image", title: TrialCopy.Crosshair.image, isOptional: true),
            ] },
            completed: {
                guard let start = session.crosshairStart else { return [] }
                let now = crosshair.settings
                var done: Set<String> = []
                if self.isOn(.crosshair) { done.insert("on") }
                if now.shape != start.shape && now.shape != .image { done.insert("shape") }
                if now.fillHex != start.fillHex { done.insert("color") }
                if now.offsetX != start.offsetX || now.offsetY != start.offsetY { done.insert("offset") }
                if now.shape == .image, now.imageName != nil, start.shape != .image || now.imageName != start.imageName {
                    done.insert("image")
                }
                return done
            },
            controls: { AnyView(TrialToolControls(model: self, tool: .crosshair)) },
            onAppear: { if session.crosshairStart == nil { session.crosshairStart = crosshair.settings } })
    }

    /// Timer Overlay's trial (spec 5.6.9). The Test item ticks when the controller reports that the run has left;
    /// the trial keeps no timer of its own, and Test leaves the saved duration alone.
    private func timerTrial() -> TrialContent {
        guard let timer = timerOverlay else { return Self.emptyTrial }
        let session = trials
        return TrialContent(
            items: { [
                ChecklistItem(id: "on", title: TrialCopy.Timer.on, unavailableReason: self.needsAccessibility()),
                ChecklistItem(id: "test", title: TrialCopy.Timer.test, detail: TrialCopy.Timer.testDetail,
                              unavailableReason: self.needsAccessibility()),
                ChecklistItem(id: "place", title: TrialCopy.Timer.place, detail: TrialCopy.Timer.placeDetail,
                              isOptional: true, unavailableReason: self.needsAccessibility()),
                ChecklistItem(id: "key", title: TrialCopy.Timer.key, detail: TrialCopy.Timer.keyDetail, isOptional: true),
            ] },
            completed: {
                guard let start = session.timerStartOffset, let keysAtStart = session.timerKeysAtStart else { return [] }
                var done: Set<String> = []
                if self.isOn(.timerOverlay) { done.insert("on") }
                if session.timerTestLeft { done.insert("test") }
                if [timer.settings.offsetX, timer.settings.offsetY] != start { done.insert("place") }
                let keys = Self.startTimerKeys(in: self.hotkeys.bindings)
                if !keys.isEmpty && keys != keysAtStart { done.insert("key") }
                return done
            },
            controls: { AnyView(TrialToolControls(model: self, tool: .timerOverlay)) },
            onAppear: {
                if session.timerStartOffset == nil { session.timerStartOffset = [timer.settings.offsetX, timer.settings.offsetY] }
                if session.timerKeysAtStart == nil { session.timerKeysAtStart = Self.startTimerKeys(in: self.hotkeys.bindings) }
                session.watch(for: .timerOverlay) {
                    if timer.phase == .idle {
                        if session.timerTestRunning {
                            session.timerTestRunning = false
                            session.timerTestLeft = true
                        }
                    } else {
                        // A key press during Test starts a real countdown, which isn't the test (plan decision 9).
                        session.timerTestRunning = timer.isTestRun
                    }
                }
            },
            onDisappear: { session.stopWatching(.timerOverlay) })
    }

    /// The hotkeys that start the timer, with their keys.
    static func startTimerKeys(in bindings: [HotkeyBinding]) -> [UUID: HotkeyCombo] {
        Dictionary(uniqueKeysWithValues: bindings.filter { $0.actions.contains(.startTimer) }.map { ($0.id, $0.combo) })
    }

    private func backdropTrial() -> TrialContent {
        guard let backdrop = controller(for: .windowBackdrop, as: BackdropController.self) else { return Self.emptyTrial }
        let session = trials
        return TrialContent(
            items: { [
                ChecklistItem(id: "on", title: TrialCopy.Backdrop.on,
                              detail: self.minecraft.active == nil ? TrialCopy.Backdrop.onWithoutMinecraft : TrialCopy.Backdrop.onWithMinecraft,
                              unavailableReason: self.needsAccessibility()),
                ChecklistItem(id: "fill", title: TrialCopy.Backdrop.fill),
            ] },
            completed: {
                guard let start = session.backdropStartFill else { return [] }
                var done: Set<String> = []
                if self.isOn(.windowBackdrop) { done.insert("on") }
                if backdrop.settings.fill != start { done.insert("fill") }
                return done
            },
            controls: { AnyView(TrialToolControls(model: self, tool: .windowBackdrop)) },
            onAppear: {
                if session.backdropStartFill == nil { session.backdropStartFill = backdrop.settings.fill }
                // Without Minecraft the backdrop shows its effect behind the sTools window itself (spec D6).
                backdrop.standIn = Self.mainWindowStandIn()
            },
            onDisappear: { backdrop.standIn = nil })
    }

    /// The sTools window and the display it's on.
    private static func mainWindowStandIn() -> BackdropStandIn? {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let number = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return BackdropStandIn(windowNumber: window.windowNumber, displayID: number.uint32Value)
    }

    private func nbbTrial() -> TrialContent {
        guard let nbb = controller(for: .nbbOverlay, as: NBBOverlayController.self) else { return Self.emptyTrial }
        let session = trials
        return TrialContent(
            items: { [
                ChecklistItem(id: "on", title: TrialCopy.NBB.on, unavailableReason: self.needsAccessibility()),
                ChecklistItem(id: "place", title: TrialCopy.NBB.place, detail: TrialCopy.NBB.placeDetail),
                ChecklistItem(id: "measure", title: TrialCopy.NBB.measure, detail: TrialCopy.NBB.measureDetail,
                              unavailableReason: nbb.isReachable ? nil : TrialCopy.NBB.sample),
            ] },
            completed: {
                guard let start = session.nbbStartOffset else { return [] }
                var done: Set<String> = []
                if self.isOn(.nbbOverlay) { done.insert("on") }
                if [nbb.settings.offsetX, nbb.settings.offsetY] != start { done.insert("place") }
                if session.nbbSawUpdate { done.insert("measure") }
                return done
            },
            controls: { AnyView(TrialToolControls(model: self, tool: .nbbOverlay)) },
            onAppear: {
                if session.nbbStartOffset == nil { session.nbbStartOffset = [nbb.settings.offsetX, nbb.settings.offsetY] }
                nbb.sample = Self.sampleStronghold
                session.watch(for: .nbbOverlay) {
                    guard let result = nbb.stronghold else { return }
                    if let first = session.nbbFirstResult {
                        if result != first && !result.eyeThrows.isEmpty { session.nbbSawUpdate = true }
                    } else {
                        session.nbbFirstResult = result
                    }
                }
            },
            onDisappear: {
                nbb.sample = nil
                session.stopWatching(.nbbOverlay)
            })
    }

    /// The Prologue's sample Ninjabrain Bot result, decoded once.
    static let sampleStronghold: NBBEvents.Stronghold? = try? JSONDecoder().decode(
        NBBEvents.Stronghold.self, from: Data(PrologueSamples.ninjabrainBotStronghold.utf8))

    private func recordingTrial() -> TrialContent {
        guard let recording = controller(for: .screenRecording, as: ScreenRecordingController.self) else { return Self.emptyTrial }
        let session = trials
        return TrialContent(
            items: { [
                ChecklistItem(id: "source", title: TrialCopy.Recording.source, detail: TrialCopy.Recording.sourceDetail),
                ChecklistItem(id: "record", title: TrialCopy.Recording.record, detail: TrialCopy.Recording.recordDetail,
                              unavailableReason: self.needsAccessibility()
                                ?? (recording.screenRecordingPermission == .granted ? nil : TrialCopy.needsScreenRecording)),
                ChecklistItem(id: "play", title: TrialCopy.Recording.play),
            ] },
            completed: {
                guard let start = session.recordingStartSources else { return [] }
                var done: Set<String> = []
                let sources = recording.layout.videoSources
                if !sources.isEmpty && sources != start { done.insert("source") }
                if Self.testClip(recording, session) != nil { done.insert("record") }
                if session.didPlayBack { done.insert("play") }
                return done
            },
            controls: { AnyView(VStack(alignment: .leading, spacing: 18) {
                TestRecordingPlate(model: self, recording: recording, session: session)
                TrialToolControls(model: self, tool: .screenRecording)
            }) },
            onAppear: {
                if session.recordingStartSources == nil { session.recordingStartSources = recording.layout.videoSources }
                if !session.recordingBaselineTaken {
                    session.recordingBaselineTaken = true
                    session.recordingSavedAtStart = recording.lastSaved
                }
            })
    }

    /// The clip saved during the trial, if any.
    static func testClip(_ recording: ScreenRecordingController, _ session: TrialSession) -> URL? {
        guard let saved = recording.lastSaved, saved != session.recordingSavedAtStart else { return nil }
        return saved.files.first
    }

    private func keyRebinderTrial() -> TrialContent {
        guard let keyRebinder else { return Self.emptyTrial }
        let session = trials
        return TrialContent(
            items: { [
                ChecklistItem(id: "layout", title: TrialCopy.KeyRebinder.layout),
                ChecklistItem(id: "find", title: TrialCopy.KeyRebinder.find, detail: TrialCopy.KeyRebinder.findDetail),
                ChecklistItem(id: "tester", title: TrialCopy.KeyRebinder.tester, detail: TrialCopy.KeyRebinder.testerDetail),
                ChecklistItem(id: "profiles", title: TrialCopy.KeyRebinder.profiles,
                              unavailableReason: keyRebinder.canEdit ? nil : TrialCopy.needsKarabiner),
                ChecklistItem(id: "rebind", title: TrialCopy.KeyRebinder.rebind, isOptional: true,
                              unavailableReason: keyRebinder.canEdit ? nil : TrialCopy.needsKarabiner),
            ] },
            completed: {
                var done: Set<String> = []
                if keyRebinder.layout != nil { done.insert("layout") }
                if keyRebinder.selectedKey != nil { done.insert("find") }
                if session.testedKeys.count >= 3 { done.insert("tester") }
                if session.openedProfileMenu { done.insert("profiles") }
                if session.madeAndRemovedRebind { done.insert("rebind") }
                return done
            },
            controls: { AnyView(TrialToolControls(model: self, tool: .keyRebinder)) },
            onAppear: {
                session.watchProfileMenu()
                session.watch(for: .keyRebinder) {
                    let lit = keyRebinder.litKeys
                    if !lit.isSubset(of: session.testedKeys) { session.testedKeys.formUnion(lit) }
                }
                session.watch(for: .keyRebinder) {
                    guard keyRebinder.config != nil else { return }
                    let rebinds = Set(keyRebinder.derived.rebinds)
                    guard let start = session.rebindsAtStart else {
                        session.rebindsAtStart = rebinds
                        return
                    }
                    if !rebinds.isSubset(of: start) { session.madeRebind = true }
                    if session.madeRebind && rebinds == start { session.madeAndRemovedRebind = true }
                }
            },
            onDisappear: { session.stopWatching(.keyRebinder) })
    }
}
