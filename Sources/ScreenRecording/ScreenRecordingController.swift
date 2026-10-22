import AppKit
import Foundation
import Observation
import STPlatform

/// Owns Screen Recording (spec 5.4). The tool's switch arms the recorder: the sources run, the plate shows the
/// live composite, and Record starts writing at once. Layout edits are saved as they happen and are locked while
/// recording.
///
/// Stopping a recording turns the tool off (spec 5.4.4): the Save/Delete question comes up (`decisionPresenter`), and
/// once it's answered, or the recording is saved without asking, the tool switches off. A start canceled before
/// anything was written (while the sources start, or during the countdown) switches it off too. Only the Prologue's
/// 5-second test leaves it on.
@MainActor
@Observable
public final class ScreenRecordingController: ToolController {
    public enum Phase: Equatable {
        case idle
        /// A recording was asked for and nothing is written yet: the sources are starting (switching the tool on arms
        /// them first, which can take a second or two). Writing begins as soon as they run, after the countdown when
        /// one is set. The key, the page's Cancel or switching the tool off cancels it, and nothing is left behind.
        case starting
        case countingDown(Int)
        case recording
        case finishing
        /// Stopped; waiting for Save or Delete.
        case deciding
    }

    /// What one press of Screen Recording's key did (spec 5.4.4, 6.1), for the confirmation over the game. It's known
    /// as the press returns; the start and the stop carry on after it.
    public enum KeyPress: Equatable, Sendable {
        /// A recording started, the tool switched on first when it was off. It writes as soon as the sources run.
        case started
        /// The countdown (Advanced) started; the recording starts when it runs out.
        case countdown(seconds: Int)
        /// The recording stopped; the question asks for its name and Save or Delete.
        case stopped
        /// A start was canceled before anything was written (the sources were starting, or the countdown ran), and
        /// the tool switched off.
        case canceled
        /// The last recording still waits for Save or Delete; the question comes forward again.
        case awaitingDecision
        /// The last recording is still being finished; nothing changed.
        case finishing
        /// The tool couldn't switch on (it needs Accessibility, rule R10), so nothing started.
        case couldNotSwitchOn
    }

    /// A finished recording waiting for its Save/Delete answer.
    public struct Finished: Equatable {
        public var files: [URL]
        public var seconds: Double
        public var droppedFrames: Int
        /// Why it stopped early, when it did.
        public var explanation: String?
        /// The name it was written under, its date and time (`2026-10-13 21.04.37`): the name the question offers,
        /// and the one it keeps when it's saved without one or the question is canceled.
        public var name: String
        /// The Prologue's 5-second test, which leaves the tool on once saved.
        var isTest = false
    }

    public private(set) var isEnabled = false
    /// Switches the tool on through the app (its sidebar switch and the Accessibility rule, R10); returns whether
    /// it is on afterwards. Without it, the controller switches itself on.
    @ObservationIgnored public var requestEnable: (@MainActor () -> Bool)?
    /// Switches the tool off through the app (its sidebar switch) once a stopped recording is saved or deleted.
    /// Without it, the controller switches itself off.
    @ObservationIgnored public var requestDisable: (@MainActor () -> Void)?
    /// Asks Save or Delete once a recording stops, in front of whatever app is, Minecraft included. The app gives it a
    /// floating panel of its own; tests give it a fake or nothing.
    @ObservationIgnored public var decisionPresenter: (any RecordingDecisionPresenting)?
    public private(set) var phase = Phase.idle
    public private(set) var finished: Finished?
    public private(set) var lastSaved: RecordingFinisher.SaveResult?
    /// Things that happened to sources (spec 5.4.6), newest last.
    public private(set) var notes: [String] = []
    public private(set) var elapsedSeconds = 0.0
    public private(set) var fileSize: Int64 = 0
    public private(set) var droppedFrames = 0
    public private(set) var available = AvailableSources()
    public private(set) var preview: CGImage?
    /// Shown instead of the preview when there's nothing to show.
    public private(set) var previewMessage: String?

    public var options: RecordingOptions {
        didSet {
            guard options != oldValue else { return }
            services.settings.save(options)
            if isEnabled, phase == .idle, captureAffecting(options) != captureAffecting(oldValue) { rearm() }
        }
    }

    /// Edits are refused while recording (spec 5.4.3: the layout is locked).
    public private(set) var layout: RecordingLayout

    @ObservationIgnored private let services: ToolServices
    /// Builds the capture objects for one arming, at the frame rate then chosen.
    @ObservationIgnored private let makeFactory: @MainActor (Int) -> any CaptureFactory
    /// Lists what Add Source can offer; replaced in tests so ScreenCaptureKit never asks for permission there.
    @ObservationIgnored private let loadAvailable: @MainActor (Set<Int32>) async -> AvailableSources
    /// sTools' own sound, such as Timer Overlay's alarm: every feed is listened to while armed, and a recording
    /// gets a track for each one that wants recording when it starts.
    @ObservationIgnored private let inProcessAudio: InProcessAudio
    @ObservationIgnored private var rig: CaptureRig?
    @ObservationIgnored private var session: RecordingSession?
    /// The latest arming: starting the sources when the tool switches on, or restarting them after a change. A start
    /// waits for it.
    @ObservationIgnored private var armTask: Task<Void, Never>?
    /// Counts armings, so only the latest one marks the sources ready (`sourcesAreReady`).
    @ObservationIgnored private var armCount = 0
    @ObservationIgnored private var armedCount = 0
    /// Counts starts, so a start that was canceled while it waited never writes.
    @ObservationIgnored private var startCount = 0
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewCompositor: Compositor?
    @ObservationIgnored private var armedMinecraftID: Int32?
    @ObservationIgnored private var recordingDisplaySize: PixelSize?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var previewIsVisible = false

    public init(
        services: ToolServices, makeFactory: (@MainActor (Int) -> any CaptureFactory)? = nil,
        loadAvailable: (@MainActor (Set<Int32>) async -> AvailableSources)? = nil,
        inProcessAudio: InProcessAudio = .shared, decisionPresenter: (any RecordingDecisionPresenting)? = nil
    ) {
        self.services = services
        self.inProcessAudio = inProcessAudio
        self.decisionPresenter = decisionPresenter
        options = services.settings.load(RecordingOptions.self)
        layout = services.settings.load(RecordingLayout.self)
        self.makeFactory = makeFactory ?? { SystemCaptureFactory(frameRate: $0) }
        self.loadAvailable = loadAvailable ?? { await AvailableSources.load(excludingProcessIDs: $0) }
        convertLegacyLayout()
        watchMinecraft()
        watchDisplays()
    }

    /// A layout saved by version 1 holds canvas pixels; it's turned into fractions of the canvas once, here, and
    /// saved, so it never converts again.
    private func convertLegacyLayout() {
        guard layout.holdsLegacyPixels else { return }
        layout.convertLegacyPixels(canvas: canvas)
        services.settings.save(layout)
    }

    public var isRecording: Bool { phase == .recording }
    /// From the moment a start is asked for until the recording is stopped: the sources it starts with stay as they are.
    public var isLayoutLocked: Bool { phase != .idle && phase != .deciding }

    // MARK: Canvas

    /// Minecraft's display at its backing-pixel size, which is what the base layer is captured at. It changes with
    /// the display's resolution and backing scale; the layout is saved as fractions of the canvas, so it doesn't.
    public var minecraftDisplaySize: PixelSize {
        let display = services.minecraft.active?.displayID.flatMap { id in services.displays.displays.first { $0.id == id } }
            ?? services.displays.main
        guard let display else { return PixelSize(width: 1920, height: 1080) }
        return PixelSize(width: Int(display.frame.width * display.backingScale), height: Int(display.frame.height * display.backingScale))
    }

    public var canvas: PixelSize { LayoutMath.canvasSize(options.canvas, minecraftDisplay: minecraftDisplaySize) }

    /// Where the Save/Delete question goes when sTools' window isn't in front: Minecraft's display, else the main
    /// display.
    var decisionDisplay: DisplayInfo? {
        let displays = services.displays.displays
        if let id = services.minecraft.active?.displayID, let display = displays.first(where: { $0.id == id }) {
            return display
        }
        return displays.first(where: \.isMain) ?? displays.first
    }

    // MARK: ToolController

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            arm()
        } else {
            // A start ends here, before anything is written; a recording stops (and asks) as the sources go. Switched
            // back on before that runs, the tool keeps its sources, and a start made since goes on.
            endStart()
            Task {
                guard !isEnabled else { return }
                await disarm()
            }
        }
    }

    /// Starts the sources, or with `restarting`, stops and starts them again; `armTask` is what a start waits for.
    private func arm(restarting: Bool = false) {
        armTask?.cancel()
        armCount += 1
        let count = armCount
        armTask = Task { [weak self] in
            guard let self else { return }
            if restarting { await self.tearDownRig() }
            await self.refreshAvailableSources()
            await self.buildRig()
            if count > self.armedCount { self.armedCount = count }
        }
    }

    /// A setting, a source, Minecraft or a display changed while idle. The restart is the arming a start waits for,
    /// so a press just after the change records with the new sources instead of the ones being stopped.
    private func rearm() {
        arm(restarting: true)
    }

    /// The sources run and nothing is restarting them, so a start can write at once, without waiting.
    private var sourcesAreReady: Bool { rig != nil && armedCount == armCount }

    private func disarm() async {
        armTask?.cancel()
        if phase == .recording { await stopRecording(explanation: nil) }
        endStart()
        await tearDownRig()
    }

    private func buildRig() async {
        guard isEnabled, rig == nil else { return }
        let factory = makeFactory(options.frameRate.framesPerSecond)
        var video: [SourceKey: any VideoCapture] = [:]
        var audio: [AudioTrackID: any AudioCapture] = [:]
        let minecraft = services.minecraft.active
        armedMinecraftID = minecraft?.id
        if let minecraft, let base = factory.base(minecraftWindowID: minecraft.window.windowNumber, showsCursor: options.showCursor) {
            video[.base] = base
            if layout.includesMinecraftAudio, let sound = factory.minecraftAudio(processID: minecraft.window.processID) {
                audio[.minecraft] = sound
            }
            previewMessage = nil
        } else {
            previewMessage = "Open Minecraft to see it here. Sources you add are recorded either way."
        }
        for source in layout.videoSources {
            var source = source
            if case .window(let reference) = source.kind, let found = available.resolve(reference), found != reference {
                source.kind = .window(found)
                updateLayout { layout in
                    if let index = layout.videoSources.firstIndex(where: { $0.id == source.id }) { layout.videoSources[index].kind = .window(found) }
                }
            }
            if let capture = factory.video(for: source, canvas: canvas, showsCursor: options.showCursor) { video[.source(source.id)] = capture }
        }
        for source in layout.audioSources {
            if let capture = factory.audio(for: source) { audio[.source(source.id)] = capture }
        }
        for feed in inProcessAudio.feeds {
            audio[.feed(feed.name)] = FeedCapture(feed: feed)
        }
        let rig = CaptureRig(video: video, audio: audio, minimizedShowsNothing: options.minimizedWindowBehavior == .showNothing)
        self.rig = rig
        listen(to: rig)
        await rig.start()
        guard self.rig === rig else { return }
        startPreview()
    }

    private func tearDownRig() async {
        previewTask?.cancel()
        previewTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        preview = nil
        let old = rig
        rig = nil
        await old?.stop()
    }

    /// Re-arms when Minecraft opens or quits, unless recording (a recording continues without it).
    private func watchMinecraft() {
        withObservationTracking {
            _ = services.minecraft.active?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isEnabled, self.phase == .idle, self.services.minecraft.active?.id != self.armedMinecraftID { self.rearm() }
                self.watchMinecraft()
            }
        }
    }

    /// A display changing resolution or backing scale changes the pixel size its windows and its whole picture are
    /// captured at, while running streams keep the size they started with. Re-arming while idle starts them again at
    /// the new size, so each source's content keeps filling the frame it's fitted into. (While recording, Minecraft's
    /// display changing stops the recording, spec 5.4.6.)
    private func watchDisplays() {
        withObservationTracking {
            _ = services.displays.displays
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isEnabled, self.phase == .idle, self.rig != nil { self.rearm() }
                self.watchDisplays()
            }
        }
    }

    // MARK: Events (spec 5.4.6)

    private func listen(to rig: CaptureRig) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in rig.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: RigEvent) {
        switch event {
        case .started:
            break
        case .failedToStart(let key, let reason):
            note("\(title(of: key)) couldn\u{2019}t start: \(reason)")
        case .audioFailedToStart(let id, let reason):
            note("\(title(of: id)) sound couldn\u{2019}t start: \(reason)")
        case .ended(.base, _):
            if phase == .recording, services.minecraft.active != nil {
                Task { await stopRecording(explanation: "Minecraft\u{2019}s capture stopped (its display changed, or Screen Recording permission was turned off), so the recording was finished.") }
            } else {
                note("Minecraft\u{2019}s window closed. Recording continues with your other sources.")
            }
        case .ended(let key, _):
            note("\(title(of: key)) closed; its place stays empty\(phase == .recording ? " for the rest of the recording" : "").")
        }
    }

    private func note(_ text: String) {
        notes.append(text)
        if notes.count > 20 { notes.removeFirst(notes.count - 20) }
    }

    public func clearNotes() { notes = [] }

    private func title(of key: SourceKey) -> String {
        switch key {
        case .base: "Minecraft"
        case .source(let id): layout.videoSources.first { $0.id == id }?.title ?? "A source"
        }
    }

    private func title(of id: AudioTrackID) -> String {
        switch id {
        case .minecraft: "Minecraft\u{2019}s"
        case .source(let sourceID): "\(layout.audioSources.first { $0.id == sourceID }?.name ?? "A source")\u{2019}s"
        case .feed(let name): "\(name)\u{2019}s"
        }
    }

    // MARK: Recording

    /// Screen Recording's key (spec 5.4.4, 6.1): starts a recording, switching the tool on first when it's off, and
    /// stops one, which asks Save or Delete. Pressed before anything is written (while the sources start, or during
    /// the countdown), it cancels the start and the tool switches off. While the question waits for its answer it
    /// brings it forward again. Returns what the press did; the start and the stop carry on after it returns.
    @discardableResult
    public func toggleRecording() -> KeyPress {
        switch phase {
        case .recording:
            Task { await stopRecording(explanation: nil) }
            return .stopped
        case .starting, .countingDown:
            cancelStart()
            return .canceled
        case .deciding:
            presentDecision()
            return .awaitingDecision
        case .finishing:
            return .finishing
        case .idle:
            let (press, start) = beginStart(isTest: false)
            if let start { Task { await run(start) } }
            return press
        }
    }

    /// Record on the page: starts a recording as the key does, switching the tool on first when it's off. Returns
    /// once it writes, or once the start ended without a recording (canceled or failed).
    public func startRecording() async {
        await startRecording(isTest: false)
    }

    private func startRecording(isTest: Bool) async {
        guard phase == .idle else { return }
        let (_, start) = beginStart(isTest: isTest)
        if let start { await run(start) }
    }

    /// One start, from the press until the first frame is written.
    private struct Start {
        let number: Int
        let countdown: Countdown
        /// The Prologue's 5-second test, which leaves the tool on whatever happens.
        let isTest: Bool
    }

    /// The part of a start that can't wait: switches the tool on when it's off, then marks the start (`.starting`)
    /// before anything waits, so a press while the sources come up finds it and cancels it instead of starting a
    /// second recording.
    private func beginStart(isTest: Bool) -> (KeyPress, Start?) {
        if !isEnabled {
            if let requestEnable { guard requestEnable() else { return (.couldNotSwitchOn, nil) } } else { setEnabled(true) }
        }
        startCount += 1
        phase = .starting
        let countdown = options.countdown
        let start = Start(number: startCount, countdown: countdown, isTest: isTest)
        return (countdown == .off ? .started : .countdown(seconds: countdown.seconds), start)
    }

    /// The rest of a start: waits for the sources, runs the countdown, then writes. It leaves off as soon as the start
    /// was canceled.
    private func run(_ start: Start) async {
        // The sources come up after switching on, or restart after a change made just before the press: the latest
        // arming is the one to wait for. Already running, nothing waits, so Record writes at once.
        var awaited: Task<Void, Never>?
        while !sourcesAreReady, let task = armTask, task != awaited {
            awaited = task
            await task.value
            guard isCurrent(start) else { return }
        }
        if start.countdown != .off {
            for remaining in stride(from: start.countdown.seconds, to: 0, by: -1) {
                phase = .countingDown(remaining)
                try? await Task.sleep(for: .seconds(1))
                guard isCurrent(start) else { return }
            }
        }
        beginWriting(start)
    }

    /// Whether `start` is still the one under way: not canceled, and no other start since.
    private func isCurrent(_ start: Start) -> Bool {
        guard start.number == startCount else { return false }
        switch phase {
        case .starting, .countingDown: return true
        default: return false
        }
    }

    /// The key, or the page's Cancel, before anything was written (while the sources start or the countdown runs):
    /// the recording never began, so the start ends and the tool switches off, as after a stop.
    public func cancelStart() {
        guard endStart() else { return }
        switchOff()
    }

    /// Ends a start before anything was written, leaving the tool as it is. True when one was under way.
    @discardableResult
    private func endStart() -> Bool {
        switch phase {
        case .starting, .countingDown:
            phase = .idle
            return true
        default:
            return false
        }
    }

    private func beginWriting(_ start: Start) {
        guard isCurrent(start) else { return }
        // A recording can only begin from a start with its sources up, never over one already writing.
        guard session == nil, let rig else {
            endStart()
            note("The recording couldn\u{2019}t start: its sources didn\u{2019}t start.")
            if !start.isTest { switchOff() }
            return
        }
        notes = []
        lastSaved = nil
        let configuration = RecordingSession.Configuration(
            layout: layout, options: options, canvas: canvas, baseName: RecordingFinisher.dateName(for: Date()),
            feeds: inProcessAudio.feeds.filter(\.wantsRecording).map(\.name))
        do {
            let session = try RecordingSession(configuration: configuration, rig: rig)
            try session.start()
            self.session = session
            phase = .recording
            recordingDisplaySize = minecraftDisplaySize
            elapsedSeconds = 0
            fileSize = 0
            droppedFrames = 0
            watchWriter(session)
            startReadouts(session)
            watchScreens()
        } catch {
            phase = .idle
            note("The recording couldn\u{2019}t start: \(error.localizedDescription)")
            // Nothing was recorded, so the tool switches off as after a canceled start (the test leaves it on).
            if !start.isTest { switchOff() }
        }
    }

    /// Records for `duration` and saves under the date-and-time name without asking: the Prologue's 5-second test
    /// (spec 4.2, D7: saved like any recording). Returns whether a file was saved.
    /// The tool stays on afterwards, so the test can run again at once.
    @discardableResult
    public func recordTest(for duration: Duration) async -> Bool {
        await startRecording(isTest: true)
        guard phase == .recording else { return false }
        try? await Task.sleep(for: duration)
        guard phase == .recording else { return false }
        await stop(explanation: nil, savesWithoutAsking: true, isTest: true)
        return lastSaved != nil
    }

    /// Stops and finalizes; then asks Save or Delete, or saves straight away when that question is turned off (or
    /// `savesWithoutAsking`). Either way the tool switches off once the recording is saved or deleted.
    public func stopRecording(explanation: String?, savesWithoutAsking: Bool = false) async {
        await stop(explanation: explanation, savesWithoutAsking: savesWithoutAsking, isTest: false)
    }

    private func stop(explanation: String?, savesWithoutAsking: Bool, isTest: Bool) async {
        guard phase == .recording, let session else { return }
        phase = .finishing
        readoutTask?.cancel()
        stopWatchingScreens()
        let result = await session.stop()
        self.session = nil
        droppedFrames = session.droppedFrames
        var reason = explanation
        if result.stopReason == .lowDisk { reason = "The disk is almost full, so the recording was finished." }
        if case .failed(let message) = result.stopReason { reason = "The recording stopped: \(message)" }
        let done = Finished(files: result.files, seconds: session.elapsedSeconds, droppedFrames: session.droppedFrames,
                            explanation: reason, name: session.configuration.baseName, isTest: isTest)
        guard !result.files.isEmpty else {
            phase = .idle
            if let reason { note(reason) }
            if !isTest { switchOff() }
            return
        }
        finished = done
        if options.askSaveDelete && !savesWithoutAsking {
            phase = .deciding
            decisionPresenter?.present(for: self)
        } else {
            await save(name: nil)
        }
    }

    /// Saves the finished recording under `name`, or under its date-and-time name when `name` is nil or empty. Then
    /// the tool switches off.
    public func save(name: String?) async {
        guard let finished = takeFinished() else { return }
        phase = .finishing
        lastSaved = await RecordingFinisher.save(finished.files, name: name, as: options.fileType)
        phase = .idle
        if !finished.isTest { switchOff() }
    }

    /// Removes the finished recording. Then the tool switches off.
    public func delete() {
        guard let finished = takeFinished() else { return }
        RecordingFinisher.delete(finished.files)
        phase = .idle
        if !finished.isTest { switchOff() }
    }

    /// Canceling the question (Esc) saves the recording under its date-and-time name, so nothing is ever lost.
    public func cancelDecision() async {
        await save(name: nil)
    }

    /// Brings the Save/Delete question forward again while it waits for its answer.
    public func presentDecision() {
        guard phase == .deciding else { return }
        decisionPresenter?.present(for: self)
    }

    /// Takes the recording that waits for its answer, so a second answer (a double click, quitting while it saves)
    /// finds nothing to do; the question goes away.
    private func takeFinished() -> Finished? {
        guard let finished else { return nil }
        self.finished = nil
        if phase == .deciding { decisionPresenter?.dismiss() }
        return finished
    }

    /// Stopping a recording turns the tool off (spec 5.4.4), through the app's switch when there is one.
    private func switchOff() {
        if let requestDisable { requestDisable() } else { setEnabled(false) }
    }

    public func revealLastSaved() {
        guard let files = lastSaved?.files, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// For quitting mid-recording: stop and keep the file under its date-and-time name, no questions. A question
    /// still waiting is answered the same way.
    public func finishForQuit() async {
        if phase == .recording { await stopRecording(explanation: nil, savesWithoutAsking: true) }
        if phase == .deciding { await save(name: nil) }
        await disarm()
    }

    private func watchWriter(_ session: RecordingSession) {
        Task { [weak self] in
            for await event in session.writerEvents {
                guard let self else { return }
                switch event {
                case .lowDiskWarning(let free):
                    self.note("Less than \(Self.gigabytes(free)) free on the recording disk.")
                case .stoppedForLowDisk:
                    await self.stopRecording(explanation: "The disk is almost full, so the recording was finished.")
                case .failed(let message):
                    await self.stopRecording(explanation: "The recording stopped: \(message)")
                default:
                    break
                }
            }
        }
    }

    private func startReadouts(_ session: RecordingSession) {
        readoutTask?.cancel()
        readoutTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsedSeconds = session.elapsedSeconds
                self.fileSize = session.currentFileSize
                self.droppedFrames = session.droppedFrames
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Minecraft's display changing resolution or disconnecting stops the recording (spec 5.4.6).
    private func watchScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                self.services.displays.refresh()
                if self.minecraftDisplaySize != self.recordingDisplaySize {
                    Task { await self.stopRecording(explanation: "Minecraft\u{2019}s display changed resolution or was disconnected, so the recording was finished.") }
                }
            }
        }
    }

    private func stopWatchingScreens() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // MARK: Live preview (spec 5.4.3, H18)

    /// The page calls this as it appears and disappears; the preview only runs while it's on screen.
    public func setPreviewVisible(_ visible: Bool) {
        previewIsVisible = visible
        if visible { startPreview() } else { previewTask?.cancel(); previewTask = nil }
    }

    private func startPreview() {
        guard previewIsVisible, previewTask == nil, let rig else { return }
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.phase != .recording || self.options.livePreview { self.renderPreview(rig) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func renderPreview(_ rig: CaptureRig) {
        let canvas = canvas
        let width = 640
        let size = PixelSize(width: width, height: max(2, Int(Double(width) / canvas.aspectRatio))).evenSized
        if previewCompositor?.outputSize != size { previewCompositor = try? Compositor(outputSize: size) }
        guard let compositor = previewCompositor else { return }
        let frames = rig.hub.peek()
        let plan = CompositionPlan.make(layout: layout, canvas: canvas, output: size, frames: frames.mapValues(CompositionPlan.FrameGeometry.init))
        preview = compositor.renderImage(plan, frames: frames)
    }

    // MARK: Permission and source sizes

    public var screenRecordingPermission: PermissionStatus { services.permissions.status(.screenRecording) }

    /// Asks macOS; when that leaves it missing, opens the System Settings pane.
    public func allowScreenRecording() async {
        await services.permissions.request(.screenRecording)
        if screenRecordingPermission != .granted { services.permissions.openSettings(for: .screenRecording) }
    }

    /// The size of a source's latest frame content, for crop dragging; nil before its first frame.
    public func contentSize(of id: UUID) -> PixelSize? {
        guard let frame = rig?.hub.peek()[.source(id)] else { return nil }
        let content = CompositionPlan.FrameGeometry(frame).content
        return PixelSize(width: Int(content.width.rounded()), height: Int(content.height.rounded()))
    }

    // MARK: Layout editing

    public func refreshAvailableSources() async {
        let excluded = Set([ProcessInfo.processInfo.processIdentifier] + services.minecraft.instances.map(\.window.processID))
        available = await loadAvailable(excluded)
    }

    /// Applies an edit, saves it and, when armed, restarts the sources if the set of sources changed.
    public func updateLayout(_ edit: (inout RecordingLayout) -> Void) {
        guard !isLayoutLocked else { return }
        var next = layout
        edit(&next)
        next.sanitize()
        guard next != layout else { return }
        let sourcesChanged = Self.sourceSet(next) != Self.sourceSet(layout)
        layout = next
        services.settings.save(layout)
        if sourcesChanged, isEnabled { rearm() }
    }

    public func addVideo(_ kind: VideoSourceKind, contentSize: PixelSize) {
        let canvas = canvas
        updateLayout { $0.add(VideoSource(kind: kind, frame: LayoutMath.defaultFrame(forContent: contentSize, canvas: canvas), on: canvas)) }
    }

    public func addBrowserSource(url: String) {
        var address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "https://" + address }
        let size = PixelSize(width: canvas.width / 3, height: canvas.height / 3)
        addVideo(.browser(url: address), contentSize: size)
    }

    public func addAudio(_ kind: AudioSourceKind, name: String) {
        updateLayout { $0.add(AudioSource(kind: kind, name: name)) }
    }

    public func resetToDefault() {
        options = RecordingOptions.defaultValue
    }

    /// Which sources exist, ignoring where they sit: a change here restarts capture.
    private static func sourceSet(_ layout: RecordingLayout) -> [String] {
        layout.videoSources.map { "\($0.id)\($0.kind)" }.sorted()
            + layout.audioSources.map { "\($0.id)\($0.kind)" }.sorted()
            + ["\(layout.includesMinecraftAudio)"]
    }

    private func captureAffecting(_ options: RecordingOptions) -> String {
        "\(options.showCursor)\(options.minimizedWindowBehavior)\(options.frameRate)"
    }

    /// One line for Help ▸ Copy Diagnostics.
    public var diagnosticsSummary: String {
        switch phase {
        case .recording: "Recording (\(Int(elapsedSeconds)) s)"
        case .starting, .countingDown: "Starting a recording"
        default: isEnabled ? "Armed, \(layout.videoSources.count) video and \(layout.audioSources.count) audio sources" : "Off"
        }
    }
}
