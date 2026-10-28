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

/// What the person has typed or chosen in the question so far, and which of its two panels is up: the question itself
/// or, after Delete…, the second panel that asks once more (`RecordingDeleteConfirmationView`). The panel reads it too,
/// so Esc can step back out of the second panel before it cancels the question.
@MainActor
@Observable
final class RecordingDecisionDraft {
    var name: String
    /// The second panel is up instead of the question (spec 5.4.4). Nothing is deleted until it is answered Yes.
    private(set) var confirmsDelete = false {
        didSet { if confirmsDelete != oldValue { onStepChange?() } }
    }
    /// Told when the panel to show changes, so the window shows the other one in its place.
    @ObservationIgnored var onStepChange: (() -> Void)?

    init(name: String) {
        self.name = name
    }

    /// Delete…: opens the second panel. The file stays where it is.
    func askToDelete() {
        confirmsDelete = true
    }

    /// No (and Return and Esc there): back to the question as it was, the typed name kept.
    func keep() {
        confirmsDelete = false
    }

    /// Yes: removes the recording for good.
    func deleteForGood(_ controller: ScreenRecordingController) {
        controller.delete()
    }

    /// Esc: from the second panel it is No; from the question it cancels, which saves the recording under its
    /// date-and-time name, so nothing is lost.
    func cancel(_ controller: ScreenRecordingController?) {
        if confirmsDelete {
            keep()
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

/// The question (spec 5.4.4): the recording's name, offered as its date and time, then Save or Delete…. Esc saves it
/// under that name, so nothing is ever lost. Delete… doesn't delete: it opens the second panel
/// (`RecordingDeleteConfirmationView`).
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
                        .disabled(isBusy)
                    caption(Self.savedAsLine(name: draft.name, finished: finished, options: controller.options))
                    caption(Self.escapeLine(finished: finished, options: controller.options))
                }
                answers
            }
            .padding(24)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isBusy: Bool { controller.phase != .deciding }

    private var answers: some View {
        HStack(spacing: 14) {
            Button("Delete\u{2026}") { draft.askToDelete() }
                .buttonStyle(STButtonStyle(.quiet))
            Spacer(minLength: 8)
            Button("Save", action: save)
                .buttonStyle(STButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
        .disabled(isBusy)
    }

    private func save() {
        guard !isBusy else { return }
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

/// The second panel (spec 5.4.4), shown in the question's place when Delete… is pressed: it asks once more and answers
/// Yes or No. No is the default button and the cancel, so Return and Esc go back to the question rather than delete;
/// Yes is a click away. Same plate, width and place as the question.
struct RecordingDeleteConfirmationView: View {
    @Bindable var controller: ScreenRecordingController
    @Bindable var draft: RecordingDecisionDraft
    @Environment(\.stTheme) private var theme

    /// ducky's words, exactly (2026-10-27).
    static let prompt = "Do you really want to delete this recording? It will be gone forever (a long time!)"
    static let yesTitle = "Yes"
    static let noTitle = "No"
    /// What VoiceOver says: the visible word first, then what it does.
    static let yesSpokenLabel = "Yes, delete this recording"
    static let noSpokenLabel = "No, keep this recording"

    var body: some View {
        STPlate {
            VStack(alignment: .leading, spacing: 20) {
                Text(Self.prompt)
                    .stStyle(.sectionTitle).foregroundStyle(STColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 14) {
                    Button(Self.yesTitle) { draft.deleteForGood(controller) }
                        .buttonStyle(STButtonStyle(.secondary))
                        .accessibilityLabel(Self.yesSpokenLabel)
                    Spacer(minLength: 8)
                    // The default (Return) and, with the panel's Esc, the cancel: neither can delete.
                    Button(Self.noTitle) { draft.keep() }
                        .buttonStyle(STButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(Self.noSpokenLabel)
                }
                .disabled(isBusy)
            }
            .padding(24)
        }
        .frame(width: RecordingDecisionView.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isBusy: Bool { controller.phase != .deciding }
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
///
/// Delete… shows a second panel (`RecordingDeleteConfirmationView`) in the same window: the same style and place, its
/// own height, the same non-activating panel, so it behaves over Minecraft exactly as the question does. No goes back
/// to the question, which is kept as it was (its name field and what was typed in it).
@MainActor
public final class RecordingDecisionPanel: RecordingDecisionPresenting {
    private let theme: STTheme
    private let sound: STSoundPlayer
    /// Makes the panel's window, once; tests give one that never reaches the screen.
    private let makeWindow: @MainActor () -> RecordingDecisionWindow
    private var window: RecordingDecisionWindow?

    /// The recording the panel shows, what has been typed for it, and the two panels: shown again as they were left
    /// when the question is brought back.
    private struct Shown {
        let files: [URL]
        let draft: RecordingDecisionDraft
        let question: NSView
        let confirmation: NSView
    }

    private var shown: Shown?
    /// Where the question was when the second panel took its place, and where that panel was put: No puts the question
    /// back exactly there, unless the second panel was moved meanwhile.
    private var returnFrames: (question: CGRect, confirmation: CGRect)?

    /// What has been typed and which panel is up, for tests.
    var currentDraft: RecordingDecisionDraft? { shown?.draft }

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

    /// Shows `finished`'s question, or brings it back as it was left (either panel) when it's the one already up.
    func present(_ finished: ScreenRecordingController.Finished, for controller: ScreenRecordingController) {
        let window = self.window ?? {
            let window = makeWindow()
            self.window = window
            return window
        }()
        let shown: Shown
        if let existing = self.shown, existing.files == finished.files {
            shown = existing
        } else {
            let draft = RecordingDecisionDraft(name: finished.name)
            shown = Shown(
                files: finished.files, draft: draft,
                question: host(RecordingDecisionView(controller: controller, finished: finished, draft: draft)),
                confirmation: host(RecordingDeleteConfirmationView(controller: controller, draft: draft)))
            self.shown = shown
            returnFrames = nil
            draft.onStepChange = { [weak self] in self?.stepChanged() }
        }
        let confirming = shown.draft.confirmsDelete
        let step = confirming ? shown.confirmation : shown.question
        if window.contentView !== step {
            window.releaseFieldFocus()
            window.contentView = step
        }
        window.setAccessibilityLabel(Self.accessibilityLabel(confirming: confirming))
        window.onCancel = { [weak controller, draft = shown.draft] in draft.cancel(controller) }
        window.onDefaultAction = confirming ? { [draft = shown.draft] in draft.keep() } : nil
        place(window, display: controller.decisionDisplay)
        returnFrames = nil
        window.animationBehavior = theme.reduceMotion ? .none : .alertPanel
        // In front of every app at its level, and key, without activating sTools (a non-activating panel).
        window.orderFrontRegardless()
        window.makeKey()
        window.invalidateShadow()
        if confirming { window.releaseFieldFocus() } else { window.focusFirstField() }
    }

    public func dismiss() {
        guard let window else { return }
        window.animationBehavior = theme.reduceMotion ? .none : .alertPanel
        window.orderOut(nil)
        // Let go of the controller and the recording until the next question.
        window.releaseFieldFocus()
        window.contentView = nil
        window.onCancel = nil
        window.onDefaultAction = nil
        shown?.draft.onStepChange = nil
        shown = nil
        returnFrames = nil
        // The name field no longer has the keyboard: hotkeys on typed keys come back now, not at sTools' next event.
        NSApp.updateWindows()
    }

    private func host(_ view: some View) -> NSView {
        NSHostingView(rootView: view
            .environment(\.stTheme, theme)
            .environment(\.stSoundPlayer, sound)
            .stMotionRoot(theme))
    }

    /// What VoiceOver calls the panel: the question it asks.
    static func accessibilityLabel(confirming: Bool) -> String {
        confirming ? "Delete this recording?" : "Save this recording?"
    }

    /// Delete… or No: the window shows the other panel in the same place, instantly (nothing moves, so Reduce
    /// animations has nothing to turn off), and the keyboard goes where it belongs: nowhere typed into on the second
    /// panel, the name field again, with what was typed in it, on the question.
    private func stepChanged() {
        guard let window, let shown else { return }
        let confirming = shown.draft.confirmsDelete
        let next = confirming ? shown.confirmation : shown.question
        guard window.contentView !== next else { return }
        let before = window.frame
        window.releaseFieldFocus()
        window.contentView = next
        next.layoutSubtreeIfNeeded()
        let size = next.fittingSize
        if !confirming, let frames = returnFrames, frames.confirmation == before {
            window.setFrame(frames.question, display: true)
        } else {
            window.setFrame(RecordingDecisionLayout.frame(size: size, over: before, on: visibleArea(of: window)), display: true)
        }
        returnFrames = confirming ? (before, window.frame) : nil
        window.setAccessibilityLabel(Self.accessibilityLabel(confirming: confirming))
        window.onDefaultAction = confirming ? { [draft = shown.draft] in draft.keep() } : nil
        window.invalidateShadow()
        if confirming {
            // The window's contents are new to VoiceOver: say what is being asked.
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: RecordingDeleteConfirmationView.prompt,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        } else {
            window.focusFirstField(selectingAll: false)
        }
        // The name field has the keyboard or doesn't now: hotkeys on typed keys follow at once.
        NSApp.updateWindows()
    }

    /// The visible area of the screen `window` is on.
    private func visibleArea(of window: NSWindow) -> CGRect {
        window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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
    /// Return, while the second panel is up: its default button, No. Nil on the question, where Return belongs to the
    /// name field (it saves). Handled here, ahead of any view, so Return can only ever do the safe thing.
    var onDefaultAction: (() -> Void)?

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
        if event.type == .keyDown, Self.returnKeyCodes.contains(event.keyCode), let onDefaultAction,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            // A held key repeats: only the first press answers, so No can't be pressed past the question it opens.
            if !event.isARepeat { onDefaultAction() }
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    static let escapeKeyCode: UInt16 = 53
    /// Return and the keypad's Enter.
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// Whether the name field still has to get the keyboard, once the panel is key.
    private var wantsFieldFocus = false
    /// Whether the field gets its text selected when it takes the keyboard.
    private var selectsFieldText = true

    /// Puts the keyboard in the name field with its text selected, so typing replaces the offered name: now when the
    /// panel is key, else as soon as it becomes key. The field may only exist after SwiftUI's next pass, so it's tried
    /// once more then. With `selectingAll` false (coming back from the second panel) the text is left as it was, with
    /// the insertion point at its end.
    func focusFirstField(selectingAll: Bool = true) {
        wantsFieldFocus = true
        selectsFieldText = selectingAll
        if isKeyWindow { focusPendingField() }
    }

    /// Nothing is typed into: the name field won't take the keyboard when the panel becomes key, and the keyboard
    /// leaves it now (the second panel has no field).
    func releaseFieldFocus() {
        wantsFieldFocus = false
        if firstResponder !== self { makeFirstResponder(nil) }
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
        if selectsFieldText {
            field.currentEditor()?.selectAll(nil)
        } else if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
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
