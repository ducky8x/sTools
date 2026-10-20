import AppKit
import Foundation
import Observation
import STPlatform

/// Owns Screen Recording (spec 5.4). The tool's switch arms the recorder: the sources run, the plate shows the
/// live composite, and Record starts writing at once. Layout edits are saved as they happen and are locked while
/// recording.
@MainActor
@Observable
public final class ScreenRecordingController: ToolController {
    public enum Phase: Equatable {
        case idle
        case countingDown(Int)
        case recording
        case finishing
        /// Stopped; waiting for Save or Delete.
        case deciding
    }

    /// A finished recording waiting for its Save/Delete answer.
    public struct Finished: Equatable {
        public var files: [URL]
        public var seconds: Double
        public var droppedFrames: Int
        /// Why it stopped early, when it did.
        public var explanation: String?
    }

    public private(set) var isEnabled = false
    /// Switches the tool on through the app (its sidebar switch and the Accessibility rule, R10); returns whether
    /// it is on afterwards. Without it, the controller switches itself on.
    @ObservationIgnored public var requestEnable: (@MainActor () -> Bool)?
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
    @ObservationIgnored private var rig: CaptureRig?
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var armTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var previewCompositor: Compositor?
    @ObservationIgnored private var armedMinecraftID: Int32?
    @ObservationIgnored private var recordingDisplaySize: PixelSize?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var previewIsVisible = false

    public init(
        services: ToolServices, makeFactory: (@MainActor (Int) -> any CaptureFactory)? = nil,
        loadAvailable: (@MainActor (Set<Int32>) async -> AvailableSources)? = nil
    ) {
        self.services = services
        options = services.settings.load(RecordingOptions.self)
        layout = services.settings.load(RecordingLayout.self)
        self.makeFactory = makeFactory ?? { SystemCaptureFactory(frameRate: $0) }
        self.loadAvailable = loadAvailable ?? { await AvailableSources.load(excludingProcessIDs: $0) }
        watchMinecraft()
    }

    public var isRecording: Bool { phase == .recording }
    public var isLayoutLocked: Bool { phase != .idle && phase != .deciding }

    // MARK: Canvas

    /// Minecraft's display at its backing-pixel size, which is what the base layer is captured at.
    public var minecraftDisplaySize: PixelSize {
        let display = services.minecraft.active?.displayID.flatMap { id in services.displays.displays.first { $0.id == id } }
            ?? services.displays.main
        guard let display else { return PixelSize(width: 1920, height: 1080) }
        return PixelSize(width: Int(display.frame.width * display.backingScale), height: Int(display.frame.height * display.backingScale))
    }

    public var canvas: PixelSize { LayoutMath.canvasSize(options.canvas, minecraftDisplay: minecraftDisplaySize) }

    // MARK: ToolController

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            arm()
        } else {
            Task { await disarm() }
        }
    }

    private func arm() {
        armTask?.cancel()
        armTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAvailableSources()
            await self.buildRig()
        }
    }

    private func rearm() {
        Task {
            await tearDownRig()
            arm()
        }
    }

    private func disarm() async {
        armTask?.cancel()
        if phase == .recording { await stopRecording(explanation: nil) }
        countdownTask?.cancel()
        if case .countingDown = phase { phase = .idle }
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
            if let capture = factory.video(for: source, showsCursor: options.showCursor) { video[.source(source.id)] = capture }
        }
        for source in layout.audioSources {
            if let capture = factory.audio(for: source) { audio[.source(source.id)] = capture }
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
        }
    }

    // MARK: Recording

    /// The start/stop hotkey (spec 6.1): arms first when needed.
    public func toggleRecording() {
        switch phase {
        case .recording: Task { await stopRecording(explanation: nil) }
        case .countingDown: cancelCountdown()
        case .idle: Task { await startRecording() }
        case .finishing, .deciding: break
        }
    }

    public func startRecording() async {
        guard phase == .idle else { return }
        if !isEnabled {
            if let requestEnable { guard requestEnable() else { return } } else { setEnabled(true) }
        }
        await armTask?.value
        guard isEnabled, rig != nil else { return }
        if options.countdown != .off {
            for remaining in stride(from: options.countdown.seconds, to: 0, by: -1) {
                phase = .countingDown(remaining)
                try? await Task.sleep(for: .seconds(1))
                guard case .countingDown = phase else { return }
            }
        }
        beginWriting()
    }

    public func cancelCountdown() {
        if case .countingDown = phase { phase = .idle }
    }

    private func beginWriting() {
        guard let rig else { phase = .idle; return }
        notes = []
        lastSaved = nil
        let configuration = RecordingSession.Configuration(
            layout: layout, options: options, canvas: canvas, baseName: RecordingFinisher.dateName(for: Date()))
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
        }
    }

    /// Records for `duration` and saves under the date-and-time name without asking: the Prologue's 5-second test
    /// (spec 4.2, D7: saved like any recording). Returns whether a file was saved.
    @discardableResult
    public func recordTest(for duration: Duration) async -> Bool {
        await startRecording()
        guard phase == .recording else { return false }
        try? await Task.sleep(for: duration)
        guard phase == .recording else { return false }
        await stopRecording(explanation: nil, savesWithoutAsking: true)
        return lastSaved != nil
    }

    /// Stops and finalizes; then asks Save or Delete, or saves straight away when that question is turned off (or
    /// `savesWithoutAsking`).
    public func stopRecording(explanation: String?, savesWithoutAsking: Bool = false) async {
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
        let done = Finished(files: result.files, seconds: session.elapsedSeconds, droppedFrames: session.droppedFrames, explanation: reason)
        guard !result.files.isEmpty else {
            phase = .idle
            if let reason { note(reason) }
            return
        }
        finished = done
        if options.askSaveDelete && !savesWithoutAsking {
            phase = .deciding
        } else {
            await save(name: nil)
        }
    }

    public func save(name: String?) async {
        guard let finished else { return }
        phase = .finishing
        lastSaved = await RecordingFinisher.save(finished.files, name: name, as: options.fileType)
        self.finished = nil
        phase = .idle
    }

    public func delete() {
        guard let finished else { return }
        RecordingFinisher.delete(finished.files)
        self.finished = nil
        phase = .idle
    }

    public func revealLastSaved() {
        guard let files = lastSaved?.files, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// For quitting mid-recording: stop and keep the file under its date-and-time name, no questions.
    public func finishForQuit() async {
        if phase == .recording { await stopRecording(explanation: nil) }
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
        next.sanitize(canvas: canvas)
        guard next != layout else { return }
        let sourcesChanged = Self.sourceSet(next) != Self.sourceSet(layout)
        layout = next
        services.settings.save(layout)
        if sourcesChanged, isEnabled { rearm() }
    }

    public func addVideo(_ kind: VideoSourceKind, contentSize: PixelSize) {
        updateLayout { $0.add(VideoSource(kind: kind, frame: LayoutMath.defaultFrame(forContent: contentSize, canvas: canvas))) }
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
        default: isEnabled ? "Armed, \(layout.videoSources.count) video and \(layout.audioSources.count) audio sources" : "Off"
        }
    }
}
