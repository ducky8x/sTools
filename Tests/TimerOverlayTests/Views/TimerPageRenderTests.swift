import AppKit
import Foundation
import STDesign
import SwiftUI
import Testing
@testable import STPlatform
@testable import TimerOverlay

// Renders the Timer page offscreen at a fixed 2x, in windows that are never shown. The controller comes from the
// controller tests' `TimerRig`, with every seam faked: nothing schedules a real wake, plays a sound, shows the overlay
// or asks for a permission, and the add-file panel and the recordings warning are closures that only count their
// calls. With `STOOLS_RENDER_DIR` set, each render is also written there as a PNG, to be checked by eye.

/// Counts the page's calls into AppKit, which tests never make for real.
@MainActor
private final class ActionLog {
    var chooseCount = 0
    var confirmCount = 0

    var actions: TimerPageActions {
        TimerPageActions(
            chooseSoundFile: { [self] in chooseCount += 1; return nil },
            confirmHidingFromRecordings: { [self] in confirmCount += 1; return false })
    }
}

// MARK: - Rendering

/// A borderless window that's never shown, with a fixed backing scale, so text is rasterized at the scale it's
/// captured at.
@MainActor
private final class FixedScaleWindow: NSWindow {
    private let scale: CGFloat

    init(size: CGSize, scale: CGFloat) {
        self.scale = scale
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override var backingScaleFactor: CGFloat { scale }
}

/// Hosts a view at a fixed width in a window that's never ordered in, and captures it at 2x. The view is laid out
/// at that width, so wrapping rows and the preview's fitting see the width the page has.
@MainActor
private final class Stage {
    let host: NSHostingView<AnyView>
    let window: FixedScaleWindow
    private let width: CGFloat

    init<Content: View>(_ view: Content, width: CGFloat) {
        _ = NSApplication.shared
        STFont.register()
        self.width = width
        host = NSHostingView(rootView: AnyView(view.frame(width: width, alignment: .topLeading)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        window = FixedScaleWindow(size: host.frame.size, scale: 2)
        window.contentView = host
        fit()
    }

    /// Sizes the host to the view's height at the stage's width.
    func fit() {
        host.layoutSubtreeIfNeeded()
        let height = max(1, host.fittingSize.height.rounded(.up))
        host.setFrameSize(CGSize(width: width, height: height))
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
    }

    func capture() -> NSBitmapImageRep {
        fit()
        let size = host.bounds.size
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded()), pixelsHigh: Int((size.height * 2).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    deinit {
        MainActor.assumeIsolated { window.contentView = nil }
    }
}

/// The page as the app shows it: on the window's background, with the app's theme and motion root.
private struct PageFrame<Content: View>: View {
    let theme: STTheme
    let content: Content

    var body: some View {
        content
            .padding(24)
            .background(STColor.background)
            .environment(\.stTheme, theme)
            .stMotionRoot(theme)
    }
}

private let renderDirectory = ProcessInfo.processInfo.environment["STOOLS_RENDER_DIR"]
    .map { URL(filePath: $0, directoryHint: .isDirectory) }

/// Writes `rep` to `<STOOLS_RENDER_DIR>/<name>.png`, when that variable is set.
private func dump(_ rep: NSBitmapImageRep, _ name: String) {
    guard let renderDirectory else { return }
    try? FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?.write(to: renderDirectory.appending(path: "\(name).png"))
}

private func sameImage(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let left = a.bitmapData, let right = b.bitmapData else { return false }
    return memcmp(left, right, a.bytesPerRow * a.pixelsHigh) == 0
}

@MainActor
private func page(_ controller: TimerOverlayController, keyStatus: TimerKeyStatus = .noKey,
                  onSetInHotkeys: (@MainActor () -> Void)? = {}, log: ActionLog = ActionLog(), showsAdvanced: Bool = false,
                  theme: STTheme = STTheme()) -> PageFrame<TimerOverlaySettingsView> {
    PageFrame(theme: theme, content: TimerOverlaySettingsView(
        controller: controller, keyStatus: keyStatus, onSetInHotkeys: onSetInHotkeys, actions: log.actions,
        showsAdvanced: showsAdvanced))
}

/// Renders `view` at `width` points and 2x, writing it as `name` when asked.
@MainActor
@discardableResult
private func render<V: View>(_ view: V, width: CGFloat = 640, name: String? = nil) -> NSBitmapImageRep {
    let rep = Stage(view, width: width).capture()
    if let name { dump(rep, name) }
    return rep
}

private let f13 = TimerKeyStatus.Key(id: UUID(), name: "F13")

@Suite("Timer page", .serialized)
@MainActor
struct TimerPageRenderTests {
    // MARK: The page, checked by eye

    @Test func theDefaultPageDraws() {
        let rig = TimerRig()
        let rep = render(page(rig.controller), name: "page-default")
        #expect(rep.pixelsWide == 1_280)
        #expect(rep.pixelsHigh > 800, "the preview, the controls and the main rows")
    }

    @Test func advancedOpensWithEveryRow() {
        let rig = TimerRig()
        let closed = render(page(rig.controller))
        let open = render(page(rig.controller, showsAdvanced: true), name: "page-advanced")
        #expect(open.pixelsHigh > closed.pixelsHigh + 2_000, "Advanced holds every other row of spec 5.6.7")
    }

    /// The page at the window's minimum width: 680 pt, less the 237 pt sidebar and the page's 36 pt margins, leaves
    /// a 371 pt column.
    @Test func thePageFitsTheNarrowestWindow() {
        let rig = TimerRig {
            $0.displayChoice = .specific
            $0.soundID = "sTools:ember"
        }
        let rep = render(page(rig.controller, showsAdvanced: true), width: 371 + 48, name: "page-narrow")
        #expect(rep.pixelsWide == 838)
    }

    @Test func advancedRevealsTheRowsEachChoiceNeeds() {
        let rig = TimerRig {
            $0.showsLabel = true
            $0.nearZero = .goldThenDanger
            $0.atZero = .word
            $0.beforeZero = .chime
            $0.leave = .afterZero
            $0.displayChoice = .specific
            $0.plateColorHex = "#20304A"
            $0.ruleNote = .line
        }
        render(page(rig.controller, showsAdvanced: true), name: "page-advanced-choices")
    }

    @Test func theLooksAndPartsDraw() {
        let variants: [(String, (inout TimerOverlaySettings) -> Void)] = [
            ("look-digits-only", { $0.look = .digitsOnly }),
            ("look-compact-pill", { $0.look = .compactPill }),
            ("look-140pt", { $0.digitSize = 140 }),
            ("custom-duration", { $0.durationSeconds = 95 }),
            ("rule-line", { $0.ruleNote = .line }),
        ]
        for (name, change) in variants {
            let rig = TimerRig(settings: change)
            let rep = render(page(rig.controller), name: "page-\(name)")
            #expect(rep.pixelsWide == 1_280, "\(name)")
        }
    }

    @Test func theRuleNoticeShowsUntilDismissed() {
        let rig = TimerRig { $0.ruleNote = .lineAndNotice }
        let controller = rig.controller
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        #expect(controller.showsRuleNotice)
        let withNotice = render(page(controller), name: "page-rule-notice")
        controller.dismissRuleNotice()
        #expect(!controller.showsRuleNotice)
        let without = render(page(controller))
        #expect(withNotice.pixelsHigh > without.pixelsHigh, "the notice leaves the page; the line stays")
    }

    @Test func aRunShowsOnThePreviewAndItsButtons() {
        let rig = TimerRig()
        let controller = rig.controller
        controller.setEnabled(true)
        defer { controller.cancel(); controller.setEnabled(false) }
        #expect(controller.start())
        rig.scheduler.advance(by: 16.5)
        #expect(controller.phase == .counting)
        #expect(controller.content.text == "02:14")
        render(page(controller), name: "page-counting")
        controller.pause()
        #expect(controller.content.state == .paused)
        render(page(controller), name: "page-paused")
        controller.resume()
        rig.runToZero()
        #expect(controller.content.state == .timesUp)
        render(page(controller), name: "page-times-up")
    }

    @Test func withoutAccessibilityTheRunButtonsAreOff() {
        let rig = TimerRig(accessibility: .denied)
        render(page(rig.controller), name: "page-no-accessibility")
        let buttons = TimerRunButtons(phase: .idle, isAvailable: false, canRunTest: true)
        #expect(!buttons.canStart && !buttons.canPauseOrResume && !buttons.canCancel && !buttons.canTest)
    }

    @Test func thePreviewShrinksToFitANarrowPage() {
        let rig = TimerRig { $0.digitSize = 140 }
        let controller = rig.controller
        let narrow = render(PageFrame(theme: STTheme(), content: TimerPreviewPlate(controller: controller)), width: 300,
                            name: "preview-narrow-140pt")
        #expect(narrow.pixelsWide == 600)
        let wide = render(PageFrame(theme: STTheme(), content: TimerPreviewPlate(controller: controller)), width: 640)
        #expect(wide.pixelsHigh > narrow.pixelsHigh, "the narrow plate draws the digits smaller")
    }

    // MARK: The run buttons

    @Test(arguments: TimerPhase.allCases)
    func runButtonsFollowThePhase(phase: TimerPhase) {
        let buttons = TimerRunButtons(phase: phase, isAvailable: true, canRunTest: phase != .counting && phase != .paused)
        #expect(buttons.canStart)
        #expect(buttons.pauseTitle == (phase == .paused ? "Resume" : "Pause"))
        #expect(buttons.canPauseOrResume == (phase == .counting || phase == .paused))
        #expect(buttons.canCancel == (phase != .idle))
        #expect(buttons.canTest == (phase != .counting && phase != .paused))
    }

    // MARK: Duration

    @Test func durationChipsPickThePresetOrCustom() {
        let presets = TimerOverlaySettings.defaultPresets
        #expect(DurationPicker.choice(duration: 150, presets: presets, customPicked: false) == .preset(2))
        #expect(DurationPicker.choice(duration: 3600, presets: presets, customPicked: false) == .preset(6))
        #expect(DurationPicker.choice(duration: 95, presets: presets, customPicked: false) == .custom)
        #expect(DurationPicker.choice(duration: 150, presets: presets, customPicked: true) == .custom)
        #expect(DurationPicker.choice(duration: 150, presets: [], customPicked: false) == .custom)
    }

    // MARK: The key row

    @Test func keyRowNotesNameProblemsAndTheHotkeysSwitch() {
        #expect(TimerKeyRow.notes(for: .noKey) == [.init(text: "Hotkeys are off.", isCaution: false)])
        #expect(TimerKeyRow.notes(for: TimerKeyStatus(keys: [f13], hotkeysAreOn: true))
            == [.init(text: "Hotkeys are on.", isCaution: false)])
        let refused = TimerKeyStatus.Key(id: UUID(), name: "\u{21E7}\u{2318}2", problem: "Refused by macOS")
        let notes = TimerKeyRow.notes(for: TimerKeyStatus(keys: [f13, refused], hotkeysAreOn: false))
        #expect(notes.map(\.isCaution) == [true, true])
        #expect(notes.first?.text == "\u{21E7}\u{2318}2: Refused by macOS")
    }

    /// Advanced ▸ Cancel gesture says what the gesture does now: it switches Timer Overlay off, and the next press
    /// brings it back (spec 5.6.2).
    @Test func theCancelGestureSaysWhatItDoes() {
        #expect(TimerAdvancedSection.cancelGestureNote(for: .doublePress)
            == "A second press within 0.4 s switches Timer Overlay off. The next press switches it back on and starts.")
        #expect(TimerAdvancedSection.cancelGestureNote(for: .hold)
            == "Holding the key for 1 s switches Timer Overlay off. The next press switches it back on and starts.")
        #expect(TimerAdvancedSection.cancelGestureNote(for: .off)
            == "The key never switches Timer Overlay off; its switch does.")
    }

    @Test func setInHotkeysShowsOnlyWithItsAction() {
        let status = TimerKeyStatus(keys: [f13], hotkeysAreOn: true)
        let withButton = render(PageFrame(theme: STTheme(), content: TimerKeyRow(status: status, onSetInHotkeys: {})),
                                width: 560, name: "key-row-f13")
        let without = render(PageFrame(theme: STTheme(), content: TimerKeyRow(status: status, onSetInHotkeys: nil)),
                             width: 560, name: "key-row-trial")
        #expect(!sameImage(withButton, without))
        render(PageFrame(theme: STTheme(), content: TimerKeyRow(status: .noKey, onSetInHotkeys: {})), width: 560,
               name: "key-row-no-key")
        let problem = TimerKeyStatus(keys: [TimerKeyStatus.Key(id: UUID(), name: "F13", problem: "Refused by macOS")],
                                     hotkeysAreOn: false)
        render(PageFrame(theme: STTheme(), content: TimerKeyRow(status: problem, onSetInHotkeys: {})), width: 560,
               name: "key-row-problem")
    }

    // MARK: Motion

    /// The control for the test below: with motion on, the Custom field fades in through `stAnimation`, so a capture
    /// right after the change still shows it under way (an unshown window never advances an animation).
    @Test func theCustomFieldFadesInWithMotionOn() {
        let theme = STTheme()
        let rig = TimerRig()
        let stage = Stage(page(rig.controller, theme: theme), width: 640)
        _ = stage.capture()
        rig.controller.settings.durationSeconds = 95
        let changed = stage.capture()
        let fresh = TimerRig { $0.durationSeconds = 95 }
        #expect(!sameImage(changed, render(page(fresh.controller, theme: theme))), "the field's fade is under way")
    }

    @Test func reducedMotionShowsTheCustomFieldAtOnce() {
        let theme = STTheme(motionMode: .reduced)
        let rig = TimerRig()
        let stage = Stage(page(rig.controller, theme: theme), width: 640)
        _ = stage.capture()
        rig.controller.settings.durationSeconds = 95
        let changed = stage.capture()
        let fresh = TimerRig { $0.durationSeconds = 95 }
        #expect(sameImage(changed, render(page(fresh.controller, theme: theme))), "no fade: the Custom field is fully drawn at once")
    }

    // MARK: Cost

    @Test func thePageSchedulesNothingOfItsOwn() throws {
        let views = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/TimerOverlay/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count == 6)
        let forbidden = ["TimelineView", "Timer.publish", "scheduledTimer", "CADisplayLink", "CVDisplayLink",
                         "repeatForever", "Task.sleep", "asyncAfter", "withAnimation"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for name in forbidden {
                #expect(!source.contains(name), "\(file.lastPathComponent) uses \(name)")
            }
        }
    }

    // MARK: Sounds and the recordings warning

    @Test func addingAFileThatIsNoSoundSaysSo() throws {
        let rig = TimerRig()
        let controller = rig.controller
        let file = rig.directory.appending(path: "Not a sound.wav")
        try Data("plain text".utf8).write(to: file)
        #expect(AlarmSoundPicker.add(file, to: controller) == OwnSoundsError.notASound.errorDescription)
        #expect(controller.settings.soundID == TimerOverlaySettings.defaultSoundID)
    }

    @Test func anAddedFileBecomesTheAlarmAndCanBeRemoved() throws {
        let rig = TimerRig()
        let controller = rig.controller
        let bell = rig.directory.appending(path: "Bell.caf")
        try writeSilence(seconds: 1, to: bell)
        #expect(AlarmSoundPicker.add(bell, to: controller) == nil)
        let added = try #require(controller.sounds.first { $0.id == controller.settings.soundID })
        #expect(added.source == .file)
        render(page(controller), name: "page-own-sound")
        #expect(AlarmSoundPicker.remove(added, from: controller) == nil)
        #expect(!controller.sounds.contains(added))
        #expect(controller.settings.soundID == TimerOverlaySettings.defaultSoundID)
    }

    @Test func hidingFromRecordingsAsksFirst() {
        // Each result is worked out before `#expect`: its macro takes only Sendable closures, and these count.
        var asked = 0
        let turnedOn = TimerAdvancedSection.showsInRecordings(after: true, confirm: { asked += 1; return false })
        #expect(turnedOn)
        #expect(asked == 0, "turning it on never asks")
        let turnedOffDeclined = TimerAdvancedSection.showsInRecordings(after: false, confirm: { asked += 1; return false })
        #expect(turnedOffDeclined)
        let turnedOffConfirmed = TimerAdvancedSection.showsInRecordings(after: false, confirm: { asked += 1; return true })
        #expect(!turnedOffConfirmed)
        #expect(asked == 2)
    }

    @Test func addSoundFileAndTheWarningGoThroughTheActions() {
        let rig = TimerRig()
        let log = ActionLog()
        _ = render(page(rig.controller, log: log, showsAdvanced: true))
        #expect(log.chooseCount == 0 && log.confirmCount == 0, "rendering never opens a panel or an alert")
    }
}
