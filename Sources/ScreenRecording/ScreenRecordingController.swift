import AppKit
import Foundation
import Observation
import STPlatform

/// Owns Screen Recording (spec 5.4). The tool's switch arms the recorder: the sources run, the plate shows the
/// live composite, and Record starts writing at once. Layout edits are saved as they happen and are locked while
/// recording.
///
/// Stopping a recording turns the tool off (spec 5.4.4), right at the stop: its sources stop with it and its switch goes
/// off, the file is finished, and then the Save/Delete question comes up (`decisionPresenter`) for the finished file.
/// The answer only saves or deletes it. A start canceled before anything was written (while the sources start, or
/// during the countdown) switches the tool off too. Only the Prologue's 5-second test leaves it on.
@MainActor
@Observable
public final class ScreenRecordingController: ToolController {
    public enum Phase: Equatable {
        case idle
        /// A recording was asked for and nothing is in the file yet: the sources are starting (switching the tool on
        /// arms them first, which can take a moment), or the writer is about to write its first frame. Writing begins
        /// as soon as they run, after the countdown when one is set. The key, the page's Cancel or switching the tool
        /// off cancels it, and nothing is left behind.
        case starting
        case countingDown(Int)
        /// The writer has put the recording's first frame in the file.
        case recording
        /// A recording is being finished (its file closing, with the tool already off) or saved.
        case finishing
        /// Stopped and finished; waiting for Save or Delete. The tool is off by now, unless it was switched back on by
        /// hand.
        case deciding
    }

    /// What one press of Screen Recording's key did (spec 5.4.4, 6.1), for the confirmation over the game. It's known
    /// as the press returns; the start and the stop carry on after it.
    public enum KeyPress: Equatable, Sendable {
        /// A start is under way, the tool switched on first when it was off; nothing is in the file yet. With
        /// `waitsForSources`, its sources are still starting (switching the tool on starts them), which takes a moment;
        /// otherwise they already run and the first frame follows at once. `keyStartEnded` reports when it's written.
        case starting(waitsForSources: Bool)
        /// The countdown (Advanced) started; the recording starts when it runs out, and `keyStartEnded` reports it.
        case countdown(seconds: Int)
        /// The recording stopped and the tool switched off; once the file is finished, the question asks for its name
        /// and Save or Delete.
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
        /// Screen & System Audio Recording isn't allowed, so nothing started and the tool stayed as it was.
        case needsPermission
    }

    /// How a start the key made turned out, once it has (spec 5.4.4): the line over the game says "Recording started"
    /// only now, or why it couldn't start. A start that was canceled reports nothing here; the press that canceled it
    /// said so.
    public enum KeyStartOutcome: Equatable, Sendable {
        /// The writer put the recording's first frame in the file.
        case started
        /// It ended without a recording, for this reason: a few words for the line over the game ("the disk is almost
        /// full"); the page's note says more.
        case failed(String)
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
    }

    public private(set) var isEnabled = false
    /// Switches the tool on through the app (its sidebar switch and the Accessibility rule, R10); returns whether
    /// it is on afterwards. Without it, the controller switches itself on.
    @ObservationIgnored public var requestEnable: (@MainActor () -> Bool)?
    /// Switches the tool off through the app (its sidebar switch) when a recording stops, or a start ends without one.
    /// Without it, the controller switches itself off.
    @ObservationIgnored public var requestDisable: (@MainActor () -> Void)?
    /// Asks Save or Delete once a recording stops, in front of whatever app is, Minecraft included. The app gives it a
    /// floating panel of its own; tests give it a fake or nothing.
    @ObservationIgnored public var decisionPresenter: (any RecordingDecisionPresenting)?
    /// Told how each start the key made turned out, once it has: the app confirms it over the game.
    @ObservationIgnored public var keyStartEnded: (@MainActor (KeyStartOutcome) -> Void)?
    /// The frame clock's driver for each recording, nil for the real timer. Tests give one they fire by hand, so they
    /// decide when the first frame is written.
    @ObservationIgnored var makeTickDriver: @MainActor () -> (any TickDriver)? = { nil }
    /// The recording disk's free space, as each recording's writer reads it; tests fake a full disk.
    @ObservationIgnored var freeSpace: any FreeSpaceProvider = VolumeFreeSpaceProvider()
    /// How long a start waits for its first frame to reach the file once the writer is open, before it ends and says
    /// why. A frame normally lands within one tick.
    @ObservationIgnored var firstFrameTimeout: Duration = .seconds(5)
    /// How long a start waits for Minecraft's first frame once its capture runs, so the file doesn't open on a black
    /// canvas. ScreenCaptureKit sends a stream's first frame within a frame or two; past this, the recording starts
    /// and the game's picture joins as it comes.
    @ObservationIgnored var minecraftFrameWait: Duration = .milliseconds(500)
    public private(set) var phase = Phase.idle {
        didSet {
            guard phase != oldValue, !phaseWaiters.isEmpty else { return }
            let waiters = phaseWaiters
            phaseWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
    /// Code waiting for the phase to change (`waitWhile(_:)`), woken at each change.
    @ObservationIgnored private var phaseWaiters: [CheckedContinuation<Void, Never>] = []
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
    /// Set while sTools quits: a recording that stops now is saved under its date-and-time name instead of asking.
    @ObservationIgnored private var isQuitting = false

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
    ///
    /// Add Source's listing (ScreenCaptureKit's window list, the cameras and microphones, the apps) is read alongside:
    /// only a window source needs it first, to find its window again, so the key's start isn't held up by it otherwise.
    private func arm(restarting: Bool = false) {
        armTask?.cancel()
        armCount += 1
        let count = armCount
        armTask = Task { [weak self] in
            guard let self else { return }
            if restarting { await self.tearDownRig() }
            if self.layout.videoSources.contains(where: \.isWindow) {
                await self.refreshAvailableSources()
            } else {
                Task { await self.refreshAvailableSources() }
            }
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
        await releaseRig()?.stop()
    }

    /// Takes the sources away from the tool: the preview and the source notes stop, and switching off finds nothing
    /// left to stop. The caller stops what it got.
    private func releaseRig() -> CaptureRig? {
        previewTask?.cancel()
        previewTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        preview = nil
        let old = rig
        rig = nil
        return old
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
    /// stops one, which switches the tool off at once and then asks Save or Delete. Pressed before anything is written
    /// (while the sources start, or during the countdown), it cancels the start and the tool switches off. While the
    /// question waits for its answer it brings it forward again and starts nothing. Returns what the press did; the
    /// start and the finishing of a stopped recording carry on after it returns.
    @discardableResult
    public func toggleRecording() -> KeyPress {
        switch phase {
        case .recording:
            // The tool and its sources go off now, with the press; the file is finished after.
            if let stopping = beginStop(isTest: false) {
                Task { await finishStop(stopping, explanation: nil, savesWithoutAsking: false) }
            }
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
            let (press, start) = beginStart(isTest: false, fromKey: true)
            if let start { Task { await run(start) } }
            return press
        }
    }

    /// Record on the page: starts a recording as the key does, switching the tool on first when it's off. Returns
    /// once its first frame is in the file, or once the start ended without a recording (canceled, refused or failed).
    public func startRecording() async {
        await startRecording(isTest: false)
    }

    private func startRecording(isTest: Bool) async {
        guard phase == .idle else { return }
        let (_, start) = beginStart(isTest: isTest, fromKey: false)
        guard let start else { return }
        await run(start)
        await waitWhile { isCurrent(start) }
    }

    /// One start, from the press until the first frame is written.
    private struct Start {
        let number: Int
        let countdown: Countdown
        /// The Prologue's 5-second test, which leaves the tool on whatever happens.
        let isTest: Bool
        /// Made by the key, whose line over the game hears how it turned out (`keyStartEnded`).
        let fromKey: Bool
    }

    /// The part of a start that can't wait: switches the tool on when it's off, then marks the start (`.starting`)
    /// before anything waits, so a press while the sources come up finds it and cancels it instead of starting a
    /// second recording.
    ///
    /// Without Screen & System Audio Recording nothing starts and the tool stays as it was: there would be nothing to
    /// record but a blank canvas, and arming could bring up macOS's prompt over the game. The page's Allow… is where
    /// it's given. It's read fresh here (a cheap check that never prompts), so a grant since counts at once.
    private func beginStart(isTest: Bool, fromKey: Bool) -> (KeyPress, Start?) {
        services.permissions.refresh([.screenRecording])
        guard screenRecordingPermission == .granted else { return (.needsPermission, nil) }
        if !isEnabled {
            if let requestEnable { guard requestEnable() else { return (.couldNotSwitchOn, nil) } } else { setEnabled(true) }
        }
        startCount += 1
        phase = .starting
        let countdown = options.countdown
        let start = Start(number: startCount, countdown: countdown, isTest: isTest, fromKey: fromKey)
        let press: KeyPress = countdown == .off ? .starting(waitsForSources: !sourcesAreReady) : .countdown(seconds: countdown.seconds)
        return (press, start)
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
        // The recording's first frame shows the game: its capture runs a moment before the first frame arrives.
        if let rig, rig.hasStarted(.base) {
            _ = await rig.hub.waitForFrame(of: .base, timeout: minecraftFrameWait)
            guard isCurrent(start) else { return }
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

    /// Ends a start before anything was written, leaving the tool as it is. True when one was under way. A writer it
    /// had already opened (its first frame not in yet) is stopped and its file removed, so a canceled start never
    /// leaves anything behind.
    @discardableResult
    private func endStart() -> Bool {
        switch phase {
        case .starting, .countingDown:
            phase = .idle
            discardUnstartedSession()
            return true
        default:
            return false
        }
    }

    /// The session of a start that ended before its first frame: its clock stops now, and its file goes once closed.
    private func discardUnstartedSession() {
        guard let session else { return }
        self.session = nil
        session.stopTicking()
        Task { RecordingFinisher.delete(await session.stop().files) }
    }

    /// Opens the file and starts the frame clock. The recording has started once the writer reports its first frame
    /// (`didStartWriting`); until then it's still a start, which a press cancels.
    private func beginWriting(_ start: Start) {
        guard isCurrent(start) else { return }
        // A recording can only begin from a start with its sources up, never over one already writing.
        guard session == nil, let rig else {
            failStart(start, reason: "its sources didn\u{2019}t start")
            return
        }
        notes = []
        lastSaved = nil
        let configuration = RecordingSession.Configuration(
            layout: layout, options: options, canvas: canvas, baseName: RecordingFinisher.dateName(for: Date()),
            feeds: inProcessAudio.feeds.filter(\.wantsRecording).map(\.name))
        do {
            let session = try RecordingSession(configuration: configuration, rig: rig, driver: makeTickDriver(), freeSpace: freeSpace)
            try session.start()
            self.session = session
            watchWriter(session, start: start)
            watchForFirstFrame(session, start)
        } catch {
            failStart(start, reason: Self.startFailureReason(error), detail: error.localizedDescription)
        }
    }

    /// A start that couldn't begin writing ends without a recording: a file it opened is removed, the page says why
    /// (`detail`, or the `reason` itself), the key's line over the game hears `reason`, and the tool switches off as
    /// after a canceled start (the Prologue's test leaves it on).
    private func failStart(_ start: Start, reason: String, detail: String? = nil) {
        guard isCurrent(start) else { return }
        endStart()
        note("The recording couldn\u{2019}t start: \(detail ?? "\(reason).")")
        if start.fromKey { keyStartEnded?(.failed(reason)) }
        if !start.isTest { switchOff() }
    }

    /// Ends a start whose first frame hasn't reached the file `firstFrameTimeout` after the writer opened it, so it
    /// never hangs in "Starting".
    private func watchForFirstFrame(_ session: RecordingSession, _ start: Start) {
        let timeout = firstFrameTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.session === session, self.isCurrent(start) else { return }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            self.failStart(start, reason: "the video encoder didn\u{2019}t respond",
                           detail: "no frame reached the file in \(String(format: "%g", seconds)) seconds.")
        }
    }

    /// A few words on why a writer couldn't open its file, for the line over the game.
    static func startFailureReason(_ error: any Error) -> String {
        switch error {
        case is CompositorError: "sTools couldn\u{2019}t set up the video"
        case RecordingWriterError.fileExists: "a recording with its name is already there"
        case RecordingWriterError.invalidConfiguration: "its settings can\u{2019}t be recorded"
        case is RecordingWriterError: "the file couldn\u{2019}t be written"
        case is CocoaError: "the recordings folder can\u{2019}t be written to"
        default: "the file couldn\u{2019}t be written"
        }
    }

    /// The writer put `session`'s first frame in the file: the recording is under way, and the key's line over the
    /// game can say so.
    private func didStartWriting(_ session: RecordingSession, _ start: Start) {
        guard self.session === session, isCurrent(start) else { return }
        phase = .recording
        recordingDisplaySize = minecraftDisplaySize
        elapsedSeconds = 0
        fileSize = 0
        droppedFrames = 0
        startReadouts(session)
        watchScreens()
        if start.fromKey { keyStartEnded?(.started) }
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

    /// Stops the recording, which switches the tool off at once (spec 5.4.4), and finishes its file; then asks Save or
    /// Delete, or saves straight away when that question is turned off (or `savesWithoutAsking`).
    public func stopRecording(explanation: String?, savesWithoutAsking: Bool = false) async {
        await stop(explanation: explanation, savesWithoutAsking: savesWithoutAsking, isTest: false)
    }

    private func stop(explanation: String?, savesWithoutAsking: Bool, isTest: Bool) async {
        guard let stopping = beginStop(isTest: isTest) else { return }
        await finishStop(stopping, explanation: explanation, savesWithoutAsking: savesWithoutAsking)
    }

    /// A recording being stopped: its session, and the sources it was recorded from, which the stop now owns.
    private struct Stopping {
        let session: RecordingSession
        /// Nil for the Prologue's 5-second test, which keeps its sources running.
        let sources: CaptureRig?
    }

    /// The part of a stop that happens at the press (ducky: "stopping recording turns off the tool"): the picture ends,
    /// the sources are taken from the tool, the tool switches off, and the video sources stop, so a camera's light and
    /// macOS's recording indicator go out now rather than once the question is answered. The sound's sources run on
    /// for the recording's last samples (`finishStop`). Only the Prologue's test keeps its sources and stays on, so it
    /// can run again at once. Nil when nothing is recording.
    private func beginStop(isTest: Bool) -> Stopping? {
        guard phase == .recording, let session else { return nil }
        phase = .finishing
        session.stopTicking()
        readoutTask?.cancel()
        stopWatchingScreens()
        guard !isTest else { return Stopping(session: session, sources: nil) }
        let sources = releaseRig()
        switchOff()
        if let sources { Task { await sources.stopVideo() } }
        return Stopping(session: session, sources: sources)
    }

    /// The rest of a stop: the file takes the sound's last samples and is finished, the sound's sources stop, and then
    /// the question asks Save or Delete for the finished file (or it's saved without asking).
    private func finishStop(_ stopping: Stopping, explanation: String?, savesWithoutAsking: Bool) async {
        let session = stopping.session
        let result = await session.stop()
        await stopping.sources?.stop()
        self.session = nil
        droppedFrames = session.droppedFrames
        var reason = explanation
        if result.stopReason == .lowDisk { reason = "The disk is almost full, so the recording was finished." }
        if case .failed(let message) = result.stopReason { reason = "The recording stopped: \(message)" }
        let done = Finished(files: result.files, seconds: session.elapsedSeconds, droppedFrames: session.droppedFrames,
                            explanation: reason, name: session.configuration.baseName)
        guard !result.files.isEmpty else {
            phase = .idle
            if let reason { note(reason) }
            return
        }
        finished = done
        if options.askSaveDelete && !savesWithoutAsking && !isQuitting {
            phase = .deciding
            decisionPresenter?.present(for: self)
        } else {
            await save(name: nil)
        }
    }

    /// Saves the finished recording under `name`, or under its date-and-time name when `name` is nil or empty. The tool
    /// was switched off when the recording stopped; saving leaves it as it is.
    public func save(name: String?) async {
        guard let finished = takeFinished() else { return }
        phase = .finishing
        lastSaved = await RecordingFinisher.save(finished.files, name: name, as: options.fileType)
        phase = .idle
    }

    /// Removes the finished recording, leaving the tool as it is (off since the stop).
    public func delete() {
        guard let finished = takeFinished() else { return }
        RecordingFinisher.delete(finished.files)
        phase = .idle
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

    /// Stopping a recording turns the tool off (spec 5.4.4), and so does a start that ends without one, through the
    /// app's switch when there is one.
    private func switchOff() {
        if let requestDisable { requestDisable() } else { setEnabled(false) }
    }

    /// Returns once `condition` is false, checking it again each time the phase changes.
    private func waitWhile(_ condition: () -> Bool) async {
        while condition() {
            await withCheckedContinuation { phaseWaiters.append($0) }
        }
    }

    public func revealLastSaved() {
        guard let files = lastSaved?.files, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// For quitting: a recording still going is stopped and kept under its date-and-time name, no questions. One that
    /// was just stopped finishes first and is kept the same way, and so is one whose question still waits.
    public func finishForQuit() async {
        isQuitting = true
        defer { isQuitting = false }
        if phase == .recording { await stopRecording(explanation: nil, savesWithoutAsking: true) }
        await waitWhile { phase == .finishing }
        if phase == .deciding { await save(name: nil) }
        await disarm()
    }

    /// Follows `session`'s writer for as long as it's the one recording: its first frame starts the recording, and a
    /// full disk or a failure stops it, or ends the start when it comes before the first frame.
    private func watchWriter(_ session: RecordingSession, start: Start) {
        Task { [weak self] in
            for await event in session.writerEvents {
                guard let self, self.session === session else { return }
                switch event {
                case .firstFrameWritten:
                    self.didStartWriting(session, start)
                case .lowDiskWarning(let free):
                    self.note("Less than \(Self.gigabytes(free)) free on the recording disk.")
                case .stoppedForLowDisk:
                    if self.isCurrent(start) {
                        self.failStart(start, reason: "the disk is almost full")
                    } else {
                        await self.stopRecording(explanation: "The disk is almost full, so the recording was finished.")
                    }
                case .failed(let message):
                    if self.isCurrent(start) {
                        self.failStart(start, reason: "the file couldn\u{2019}t be written", detail: message)
                    } else {
                        await self.stopRecording(explanation: "The recording stopped: \(message)")
                    }
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
        case .finishing: "Finishing a recording"
        case .deciding: "Waiting for Save or Delete, \(isEnabled ? "on" : "off")"
        case .idle: isEnabled ? "Armed, \(layout.videoSources.count) video and \(layout.audioSources.count) audio sources" : "Off"
        }
    }
}
