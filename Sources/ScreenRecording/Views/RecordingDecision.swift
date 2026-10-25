import AppKit
import STDesign
import STPlatform
import SwiftUI

/// Shows the Save/Delete question once a recording stops (spec 5.4.4). A protocol so tests can follow the question
/// without a window.
@MainActor
public protocol RecordingDecisionPresenting: AnyObject {
    /// Shows the question for `controller`'s finished recording in front of every app, or brings it forward when it
    /// is already up.
    func present(for controller: ScreenRecordingController)
    /// Takes the question away: it has its answer.
    func dismiss()
}

/// What the person has typed or chosen in the question so far. The panel reads it too, so Esc can step back out of
/// the Delete confirmation before it cancels the question.
@MainActor
@Observable
final class RecordingDecisionDraft {
    var name: String
    var confirmsDelete = false

    init(name: String) {
        self.name = name
    }

    /// Esc: steps back out of the Delete confirmation; otherwise cancels the question, which saves the recording under
    /// its date-and-time name, so nothing is lost.
    func cancel(_ controller: ScreenRecordingController?) {
        if confirmsDelete {
            confirmsDelete = false
        } else {
            Task { await controller?.cancelDecision() }
        }
    }
}

/// Where the question goes.
enum RecordingDecisionLayout {
    /// The bottom edge's distance above a display's middle, where the crosshair is, when the question goes on a display.
    static let centerClearance: CGFloat = 48

    /// Centered over sTools' window when the person is looking at it (`window`); else on `screen` (its visible frame,
    /// AppKit coordinates), just above the middle so the crosshair at its center stays clear. Always kept on `screen`.
    static func frame(size: CGSize, over window: CGRect?, on screen: CGRect) -> CGRect {
        let width = min(size.width.rounded(.up), screen.width)
        let height = min(size.height.rounded(.up), screen.height)
        var x = (window?.midX ?? screen.midX) - width / 2
        var y = window.map { $0.midY - height / 2 } ?? screen.midY + centerClearance
        x = min(max(x, screen.minX), screen.maxX - width)
        y = min(max(y, screen.minY), screen.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }
}

/// The question (spec 5.4.4): the recording's name, offered as its date and time, then Save or Delete. Esc saves it
/// under that name, so nothing is ever lost; inside the Delete confirmation, Esc steps back to the question.
struct RecordingDecisionView: View {
    @Bindable var controller: ScreenRecordingController
    let finished: ScreenRecordingController.Finished
    @Bindable var draft: RecordingDecisionDraft
    @Environment(\.stTheme) private var theme

    static let width: CGFloat = 440

    var body: some View {
        STPlate {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save this recording?").stStyle(.sectionTitle).foregroundStyle(STColor.ink)
                Text(Self.lengthLine(finished))
                    .stStyle(.body).foregroundStyle(theme.inkSecondary)
                if let explanation = finished.explanation {
                    Text(explanation)
                        .stStyle(.body).foregroundStyle(STColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if finished.droppedFrames > 0 {
                    Text(Self.droppedLine(finished.droppedFrames))
                        .stStyle(.caption).foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").stStyle(.label).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
                    STTextField("Name", text: $draft.name)
                        .onSubmit(save)
                        .disabled(isBusy || draft.confirmsDelete)
                    caption(Self.savedAsLine(name: draft.name, finished: finished, options: controller.options))
                    caption(Self.escapeLine(finished: finished, options: controller.options))
                }
                if draft.confirmsDelete {
                    deleteConfirmation
                } else {
                    answers
                }
            }
            .padding(24)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isBusy: Bool { controller.phase != .deciding }

    private var answers: some View {
        HStack(spacing: 14) {
            Button("Delete\u{2026}") { draft.confirmsDelete = true }
                .buttonStyle(STButtonStyle(.quiet))
            Spacer(minLength: 8)
            Button("Save", action: save)
                .buttonStyle(STButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
        .disabled(isBusy)
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete this recording? The file is removed for good.")
                .stStyle(.body).foregroundStyle(STColor.danger)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Don\u{2019}t Delete") { draft.confirmsDelete = false }
                    .buttonStyle(STButtonStyle(.quiet))
                Spacer(minLength: 8)
                Button("Delete") { controller.delete() }
                    .buttonStyle(STButtonStyle(.secondary))
            }
            .disabled(isBusy)
        }
    }

    private func save() {
        guard !isBusy, !draft.confirmsDelete else { return }
        let name = draft.name
        Task { await controller.save(name: name) }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .stStyle(.caption).foregroundStyle(theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How many frames were dropped, and what to do about it.
    static func droppedLine(_ count: Int) -> String {
        "\(CountText.of(count, "frame", verb: ("was", "were"))) dropped. If Game Mode was on, macOS may have lowered "
            + "sTools\u{2019} priority; lower the frame rate or output size if this keeps happening."
    }

    /// "00:12:34 long." or "01:02:03 long, in 2 files."
    static func lengthLine(_ finished: ScreenRecordingController.Finished) -> String {
        "\(RecordBar.clock(finished.seconds)) long\(finished.files.count > 1 ? ", in \(finished.files.count) files" : "")."
    }

    /// Where Save puts it: "Saved as Seed 1.mp4 in ~/Movies/sTools.", or, with the name cleared, the date and time; the
    /// next free name ("Seed 1 2.mp4") when a recording in the folder holds that one.
    static func savedAsLine(name: String, finished: ScreenRecordingController.Finished, options: RecordingOptions) -> String {
        let fileName = plannedFileName(name: name, finished: finished, options: options)
        let folder = (options.folderPath as NSString).abbreviatingWithTildeInPath
        return RecordingFinisher.sanitizedName(name) == nil
            ? "Without a name it\u{2019}s saved as \(fileName) in \(folder)."
            : "Saved as \(fileName) in \(folder)."
    }

    /// Canceling the question still keeps the recording.
    static func escapeLine(finished: ScreenRecordingController.Finished, options: RecordingOptions) -> String {
        "Esc saves it as \(plannedFileName(name: nil, finished: finished, options: options)), so nothing is lost."
    }

    /// The first file's name as Save will make it (`RecordingFinisher.plannedFiles`).
    private static func plannedFileName(name: String?, finished: ScreenRecordingController.Finished, options: RecordingOptions) -> String {
        let planned = RecordingFinisher.plannedFiles(for: finished.files, name: name, as: options.fileType).first
        return planned?.lastPathComponent
            ?? "\(name.flatMap(RecordingFinisher.sanitizedName) ?? finished.name).\(options.fileType.fileExtension)"
    }
}

/// The question in a small floating panel of its own (spec 5.4.4), so it shows wherever the recording stopped from:
/// the key with Minecraft in front, the page's Stop, a recording that had to stop, with sTools' window closed or on
/// another page, or the introduction running. It sits over sTools' window when that's in front, else just above the
/// middle of Minecraft's display (else the main display), on every Space and over full-screen apps.
///
/// It takes the keyboard without making sTools the active app, like a launcher's panel: the app in front (Minecraft,
/// usually) stays in front, nothing waits on macOS letting sTools come forward (from the background it may not), and
/// no Space switches. The name can be typed at once (hotkeys that take typed keys pause while it's typed, as in any
/// sTools field). It stays up until it's answered, whichever app is in front; clicking it, the key or the page's
/// Save or Delete… gives it the keyboard again. Once it's answered it goes, and the keyboard goes back to the app in
/// front.
@MainActor
public final class RecordingDecisionPanel: RecordingDecisionPresenting {
    private let theme: STTheme
    private let sound: STSoundPlayer
    /// Makes the panel's window, once; tests give one that never reaches the screen.
    private let makeWindow: @MainActor () -> RecordingDecisionWindow
    private var window: RecordingDecisionWindow?
    /// The recording the panel shows, and what has been typed for it: shown again as it was when it's brought back.
    private var shown: (files: [URL], draft: RecordingDecisionDraft)?

    public convenience init(theme: STTheme, sound: STSoundPlayer = .silent) {
        self.init(theme: theme, sound: sound, makeWindow: { RecordingDecisionWindow() })
    }

    init(theme: STTheme, sound: STSoundPlayer = .silent, makeWindow: @escaping @MainActor () -> RecordingDecisionWindow) {
        self.theme = theme
        self.sound = sound
        self.makeWindow = makeWindow
    }

    public func present(for controller: ScreenRecordingController) {
        guard let finished = controller.finished else { return }
        present(finished, for: controller)
    }

    /// Shows `finished`'s question, or brings it back as it was left when it's the one already up.
    func present(_ finished: ScreenRecordingController.Finished, for controller: ScreenRecordingController) {
        let window = self.window ?? {
            let window = makeWindow()
            self.window = window
            return window
        }()
        let draft: RecordingDecisionDraft
        if let shown, shown.files == finished.files {
            draft = shown.draft
        } else {
            draft = RecordingDecisionDraft(name: finished.name)
            shown = (finished.files, draft)
            window.contentView = NSHostingView(rootView: RecordingDecisionView(controller: controller, finished: finished, draft: draft)
                .environment(\.stTheme, theme)
                .environment(\.stSoundPlayer, sound)
                .stMotionRoot(theme))
        }
        window.onCancel = { [weak controller, draft] in draft.cancel(controller) }
        place(window, display: controller.decisionDisplay)
        window.animationBehavior = theme.reduceMotion ? .none : .alertPanel
        // In front of every app at its level, and key, without activating sTools (a non-activating panel).
        window.orderFrontRegardless()
        window.makeKey()
        window.invalidateShadow()
        window.focusFirstField()
    }

    public func dismiss() {
        guard let window else { return }
        window.animationBehavior = theme.reduceMotion ? .none : .alertPanel
        window.orderOut(nil)
        // Let go of the controller and the recording until the next question.
        window.contentView = nil
        window.onCancel = nil
        shown = nil
        // The name field no longer has the keyboard: hotkeys on typed keys come back now, not at sTools' next event.
        NSApp.updateWindows()
    }

    /// Over the main window when sTools is in front with it showing, else on `display`.
    private func place(_ window: RecordingDecisionWindow, display: DisplayInfo?) {
        window.contentView?.layoutSubtreeIfNeeded()
        let size = window.contentView?.fittingSize ?? window.frame.size
        let main = NSApp.isActive ? NSApp.mainWindow.flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil } : nil
        let screen = main?.screen
            ?? display.flatMap { display in NSScreen.screens.first { $0.frame == display.frame } }
            ?? NSScreen.main
        let area = screen?.visibleFrame ?? display?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(RecordingDecisionLayout.frame(size: size, over: main?.frame, on: area), display: true)
    }
}

/// A borderless panel that takes the keyboard, so the name can be typed, and turns Esc into canceling the question.
/// It's a non-activating panel: it becomes key while another app (Minecraft) stays the active app, so showing it never
/// depends on sTools coming forward. It floats above full-screen apps and sTools' overlays, on every Space, and stays
/// up whichever app is in front until the question is answered.
class RecordingDecisionWindow: NSPanel {
    /// Esc, or anything else that cancels.
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: RecordingDecisionView.width, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        // sTools is usually in the background while it's up; AppKit would keep a window that hides on deactivation off
        // the screen all that time.
        hidesOnDeactivate = false
        // Above Minecraft in full screen and above sTools' own overlays (`.screenSaver`), like the confirmation, so the
        // crosshair never draws over it.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc cancels whichever view has the keyboard, except while an input method is composing, which Esc cancels instead.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    static let escapeKeyCode: UInt16 = 53

    /// Whether the name field still has to get the keyboard, once the panel is key.
    private var wantsFieldFocus = false

    /// Puts the keyboard in the name field with its text selected, so typing replaces the offered name: now when the
    /// panel is key, else as soon as it becomes key. The field may only exist after SwiftUI's next pass, so it's tried
    /// once more then.
    func focusFirstField() {
        wantsFieldFocus = true
        if isKeyWindow { focusPendingField() }
    }

    override func becomeKey() {
        super.becomeKey()
        focusPendingField()
        keyboardChanged()
    }

    override func resignKey() {
        super.resignKey()
        keyboardChanged()
    }

    private func focusPendingField() {
        guard wantsFieldFocus else { return }
        if focusFieldNow() { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = self?.focusFieldNow() }
        }
    }

    private func focusFieldNow() -> Bool {
        contentView?.layoutSubtreeIfNeeded()
        guard let field = Self.firstEditableField(in: contentView), makeFirstResponder(field) else { return false }
        field.currentEditor()?.selectAll(nil)
        wantsFieldFocus = false
        NSApp.updateWindows()
        return true
    }

    /// sTools' hotkeys read whether someone is typing at each app update (`NSApplication.didUpdateNotification`). With
    /// sTools in the background, nothing else may run one before the first key reaches the field, so one runs as soon
    /// as AppKit is done changing the key window: a hotkey on a typed key steps aside while the name field has the
    /// keyboard, and is back once it doesn't.
    private func keyboardChanged() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { NSApp.updateWindows() }
        }
    }

    /// The first editable text field under `view`, depth first.
    static func firstEditableField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstEditableField(in: subview) { return field }
        }
        return nil
    }
}
