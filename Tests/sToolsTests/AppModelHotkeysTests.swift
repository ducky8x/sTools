import AppKit
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

/// Stands in for the Key Rebinder's advice.
@MainActor
private final class FakeKeyboardAdvisor: HotkeyAdvising {
    var selectsKey = false
    var placementText: String?
    /// Whether a drawn key sends the combination's key; by default, whenever there is a placement text.
    var canShow: Bool?
    var cautions: [String] = []
    var notes: [String] = []
    private(set) var selected: [HotkeyCombo] = []
    private(set) var preparedCount = 0

    func notes(for combo: HotkeyCombo) -> [HotkeyNote] {
        cautions.map { HotkeyNote(tone: .caution, text: $0) } + notes.map { HotkeyNote(tone: .note, text: $0) }
    }
    func placement(of combo: HotkeyCombo) -> HotkeyPlacement? {
        HotkeyPlacement(text: placementText, canShow: canShow ?? (placementText != nil))
    }
    func selectKey(for combo: HotkeyCombo) -> Bool {
        selected.append(combo)
        return selectsKey
    }
    func prepareAdvice() async { preparedCount += 1 }
}

private let pad1 = HotkeyCombo(keyCode: 83, modifiers: [])

@MainActor
@Suite("AppModel hotkeys")
struct AppModelHotkeysTests {
    @Test func toolStatesReflectEachSwitchableToolsOnOffState() {
        let harness = Harness(accessibility: .granted)
        harness.model.setTool(.crosshair, on: true)
        let states = harness.model.hotkeyToolStates()
        #expect(states[.crosshair] == true)
        #expect(states[.nbbOverlay] == false)
        #expect(states[.windowBackdrop] == false)
        #expect(states.count == HotkeyTool.allCases.count)
    }

    @Test func handlingASetToolEventTurnsTheMappedToolOn() {
        let harness = Harness(accessibility: .granted)
        let effect = harness.model.handleHotkeyEvent(.setTool(.windowBackdrop, isOn: true))
        #expect(harness.model.isOn(.windowBackdrop))
        #expect(effect == .tool(.windowBackdrop, isOn: true))
    }

    @Test func handlingAToggleRecordingEventDoesNotCrash() {
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyEvent(.toggleRecording)
    }

    @Test func pressingARegisteredHotkeyTogglesItsToolsUsingAnyOffTurnsAllOnSemantics() async {
        let harness = Harness(accessibility: .granted)
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 8, modifiers: .control), actions: [.toggle(.crosshair), .toggle(.nbbOverlay)])
        harness.model.hotkeys.isEnabled = true
        await harness.model.settings.flush()

        // Simulate the system delivering the press.
        guard let fake = harness.hotkeyRegistrar as? FakeHotkeyRegistrar else {
            Issue.record("expected FakeHotkeyRegistrar")
            return
        }
        fake.onPress?(id)
        #expect(harness.model.isOn(.crosshair))
        #expect(harness.model.isOn(.nbbOverlay))

        // Both on: pressing again turns both off.
        fake.onPress?(id)
        #expect(!harness.model.isOn(.crosshair))
        #expect(!harness.model.isOn(.nbbOverlay))
    }

    @Test func aPressShowsOneConfirmationSayingWhatChanged() {
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true), .setTool(.nbbOverlay, isOn: true)])
        guard !harness.model.displays.displays.isEmpty else { return }
        #expect(harness.hotkeyHUD.lines == ["Crosshair on \u{00B7} NBB Overlay on"])
        #expect(harness.hotkeyHUD.presented.first?.sealed == true)

        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: false), .setTool(.nbbOverlay, isOn: false)])
        #expect(harness.hotkeyHUD.lines.last == "Crosshair off \u{00B7} NBB Overlay off")
        #expect(harness.hotkeyHUD.presented.count == 2)
    }

    @Test func theConfirmationGoesToTheMainDisplayWithoutMinecraft() throws {
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true)])
        guard let main = harness.model.displays.main else { return }
        #expect(try #require(harness.hotkeyHUD.presented.first).displayID == main.id)
    }

    @Test func aToolThatNeedsAccessibilityIsReportedNotClaimed() {
        let harness = Harness(accessibility: .denied)
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true)])
        #expect(!harness.model.isOn(.crosshair))
        guard !harness.model.displays.displays.isEmpty else { return }
        #expect(harness.hotkeyHUD.lines == ["Crosshair needs Accessibility"])
        #expect(harness.hotkeyHUD.presented.first?.sealed == false)
    }

    @Test func turningTheConfirmationOffShowsNothing() {
        let harness = Harness(accessibility: .granted)
        harness.model.hotkeys.showsConfirmation = false
        harness.model.handleHotkeyPress([.setTool(.crosshair, isOn: true)])
        #expect(harness.model.isOn(.crosshair))
        #expect(harness.hotkeyHUD.presented.isEmpty)
    }

    @Test func aPressWithNothingToActOnShowsNothing() {
        // The fake controllers include no Screen Recording controller, so the recording toggle does nothing.
        let harness = Harness(accessibility: .granted)
        harness.model.handleHotkeyPress([.toggleRecording])
        #expect(harness.hotkeyHUD.presented.isEmpty)
    }

    @Test func aRegisteredHotkeyPressIsConfirmedOnce() async {
        let harness = Harness(accessibility: .granted)
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 8, modifiers: .control),
                                           actions: [.toggle(.crosshair), .toggle(.windowBackdrop)])
        harness.model.hotkeys.isEnabled = true
        guard let fake = harness.hotkeyRegistrar as? FakeHotkeyRegistrar else {
            Issue.record("expected FakeHotkeyRegistrar")
            return
        }
        fake.onPress?(id)
        guard !harness.model.displays.displays.isEmpty else { return }
        #expect(harness.hotkeyHUD.lines == ["Crosshair on \u{00B7} Window Backdrop on"])
    }

    @Test func pressingADisabledHotkeySectionDoesNothing() {
        let harness = Harness(accessibility: .granted)
        let id = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 8, modifiers: .control), actions: [.toggle(.crosshair)])
        // isEnabled stays false (the default).
        guard let fake = harness.hotkeyRegistrar as? FakeHotkeyRegistrar else {
            Issue.record("expected FakeHotkeyRegistrar")
            return
        }
        fake.onPress?(id)
        #expect(!harness.model.isOn(.crosshair))
    }

    // MARK: Any key, and the pause

    @Test func aBareKeyHotkeyRegistersAndToggles() throws {
        let harness = Harness(accessibility: .granted)
        let fake = try #require(harness.hotkeyRegistrar as? FakeHotkeyRegistrar)
        harness.model.hotkeys.isEnabled = true
        let id = harness.model.hotkeys.add(combo: pad1, actions: [.toggle(.crosshair)])
        #expect(fake.registered == [id: pad1])
        #expect(harness.model.hotkeys.status(of: id) == .registered)

        fake.onPress?(id)
        #expect(harness.model.isOn(.crosshair))
    }

    /// The cause of "hotkeys don't work, not even in sTools": they paused whenever sTools was the active app. Now
    /// they stay registered with sTools in front and pause only while sTools listens for raw keys.
    @Test func hotkeysFireWithSToolsInFront() throws {
        let harness = Harness(accessibility: .granted)
        let fake = try #require(harness.hotkeyRegistrar as? FakeHotkeyRegistrar)
        harness.model.hotkeys.isEnabled = true
        let id = harness.model.hotkeys.add(combo: pad1, actions: [.toggle(.crosshair)])
        #expect(!harness.model.hotkeys.isPaused)
        #expect(fake.registered == [id: pad1])
        fake.onPress?(id)
        #expect(harness.model.isOn(.crosshair))

        // The same key reaching sTools' own window as a key press fires it too.
        #expect(harness.model.hotkeys.handleKeyDown(keyCode: pad1.keyCode, modifiers: [], isRepeat: false))
        #expect(!harness.model.isOn(.crosshair))
    }

    /// Typing pauses hotkeys only while sTools is the active app and an editable text view (a text field's field
    /// editor) has focus; ⌃ ⌥ ⇧ ⌘ are read the way a hotkey matches them.
    @Test func theWatcherReadsTypingAndModifiers() {
        let editable = NSTextView()
        let readOnly = NSTextView()
        readOnly.isEditable = false
        #expect(HotkeyKeyWatcher.isTyping(appIsActive: true, firstResponder: editable))
        #expect(!HotkeyKeyWatcher.isTyping(appIsActive: false, firstResponder: editable))
        #expect(!HotkeyKeyWatcher.isTyping(appIsActive: true, firstResponder: readOnly))
        #expect(!HotkeyKeyWatcher.isTyping(appIsActive: true, firstResponder: NSView()))
        #expect(!HotkeyKeyWatcher.isTyping(appIsActive: true, firstResponder: nil))
        #expect(HotkeyKeyWatcher.modifiers(of: [.control, .option, .capsLock, .function, .numericPad]) == [.control, .option])
        #expect(HotkeyKeyWatcher.modifiers(of: [.shift, .command]) == [.shift, .command])
    }

    @Test func hotkeysPauseWhileSToolsListensForKeys() throws {
        let harness = Harness(accessibility: .granted)
        let fake = try #require(harness.hotkeyRegistrar as? FakeHotkeyRegistrar)
        harness.model.hotkeys.isEnabled = true
        let id = harness.model.hotkeys.add(combo: pad1, actions: [.toggle(.crosshair)])

        harness.model.hotkeys.setPaused(true, for: .recordingKey)
        #expect(fake.registered.isEmpty)
        fake.onPress?(id)
        #expect(!harness.model.isOn(.crosshair))

        harness.model.hotkeys.setPaused(false, for: .recordingKey)
        #expect(fake.registered == [id: pad1])
        fake.onPress?(id)
        #expect(harness.model.isOn(.crosshair))
    }

    // MARK: Show on Keyboard

    @Test func showOnKeyboardAsksTheAdvisor() {
        let harness = Harness(accessibility: .granted)
        let advisor = FakeKeyboardAdvisor()
        harness.model.hotkeys.advisor = advisor

        #expect(!harness.model.showHotkeyOnKeyboard(pad1))
        #expect(advisor.selected == [pad1])
        #expect(harness.model.route == .home)

        advisor.selectsKey = true
        #expect(harness.model.showHotkeyOnKeyboard(pad1))
        #expect(harness.model.route == .tool(.keyRebinder))
    }

    @Test func showOnKeyboardWithoutTheKeyRebinderStaysPut() {
        let harness = Harness(accessibility: .granted)
        harness.model.navigate(to: .settings)
        #expect(!harness.model.showHotkeyOnKeyboard(pad1))
        #expect(harness.model.route == .settings)
    }
}

/// What a Home row says below its first line comes from the Key Rebinder's advice (spec 6.1).
@MainActor
@Suite("Home hotkey rows")
struct HomeHotkeyRowTests {
    @Test func withoutTheKeyRebinderARowSaysNothingMore() throws {
        let harness = Harness(accessibility: .granted)
        let id = harness.model.hotkeys.add(combo: pad1, actions: [.toggle(.crosshair)])
        let binding = try #require(harness.model.hotkeys.bindings.first { $0.id == id })
        // Pad 1 alone gets the typing note, which only the editor shows.
        #expect(!harness.model.hotkeys.notes(for: pad1).isEmpty)
        #expect(HotkeyBindingRow.details(for: binding, isEditing: false, hotkeys: harness.model.hotkeys) == .init())
    }

    @Test func aRowShowsThePlacementShowOnKeyboardAndTheCautionsOnly() throws {
        let harness = Harness(accessibility: .granted)
        let advisor = FakeKeyboardAdvisor()
        defer { withExtendedLifetime(advisor) {} }
        let hotkeys = harness.model.hotkeys
        hotkeys.advisor = advisor
        advisor.placementText = "On Caps Lock"
        advisor.cautions = ["Minecraft uses F3 for Debug screen. While hotkeys are on, it never gets F3."]
        advisor.notes = ["F3 won\u{2019}t fire while you hold Shift (Sneak)."]
        let id = hotkeys.add(combo: HotkeyCombo(keyCode: 99, modifiers: []), actions: [.toggle(.crosshair)])
        let binding = try #require(hotkeys.bindings.first { $0.id == id })

        let caution = HotkeyNote(tone: .caution, text: "Minecraft uses F3 for Debug screen. While hotkeys are on, it never gets F3.")
        #expect(HotkeyBindingRow.details(for: binding, isEditing: false, hotkeys: hotkeys)
            == .init(placement: "On Caps Lock", canShow: true, cautions: [caution]))
        // While the row is edited, its editor shows every note, so the row leaves the cautions out.
        #expect(HotkeyBindingRow.details(for: binding, isEditing: true, hotkeys: hotkeys)
            == .init(placement: "On Caps Lock", canShow: true))

        // No drawn key sends it: the caption, without Show on Keyboard.
        advisor.placementText = "No key on your keyboard sends F3"
        advisor.canShow = false
        #expect(HotkeyBindingRow.details(for: binding, isEditing: false, hotkeys: hotkeys)
            == .init(placement: "No key on your keyboard sends F3", canShow: false, cautions: [caution]))
        // The key simply sends itself: nothing to say about where it is.
        advisor.placementText = nil
        advisor.canShow = true
        advisor.cautions = []
        #expect(HotkeyBindingRow.details(for: binding, isEditing: false, hotkeys: hotkeys).isEmpty)
    }

    /// Several rows can offer Show on Keyboard, so VoiceOver names the hotkey on each, as it does for Edit.
    @Test func showOnKeyboardNamesItsHotkeyForVoiceOver() {
        #expect(HotkeyBindingRow.showOnKeyboardLabel(for: HotkeyCombo(keyCode: 79, modifiers: .option)) == "Show Option F18 on keyboard")
        #expect(HotkeyBindingRow.showOnKeyboardLabel(for: pad1) == "Show Keypad 1 on keyboard")
    }

    /// Home ▸ Hotkeys loads the Key Rebinder's advice (karabiner.json and Minecraft's keybinds) when it appears with
    /// hotkeys on and when they are switched on; with hotkeys off it loads nothing.
    @Test func theSectionLoadsTheAdviceWhileHotkeysAreOn() async {
        let harness = Harness(accessibility: .granted)
        let advisor = FakeKeyboardAdvisor()
        defer { withExtendedLifetime(advisor) {} }
        harness.model.hotkeys.advisor = advisor
        let size = CGSize(width: 640, height: 720)
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) { HotkeysSection(model: harness.model) }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.stTheme, harness.model.theme)
            .environment(\.stSoundPlayer, STSoundPlayer.silent))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(advisor.preparedCount == 0)

        harness.model.hotkeys.isEnabled = true
        #expect(await waitUntil {
            host.layoutSubtreeIfNeeded()
            return advisor.preparedCount == 1
        })
        withExtendedLifetime(host) {}
    }
}

@MainActor
@Suite("Home hotkeys rendering")
struct HomeHotkeysRenderTests {
    private let size = CGSize(width: 640, height: 720)

    private func render(_ harness: Harness, advancedIsOpen: Bool = false, editingID: UUID? = nil) -> NSBitmapImageRep {
        renderBitmap(
            VStack(alignment: .leading, spacing: 0) {
                HotkeysSection(model: harness.model, advancedIsOpen: advancedIsOpen, editingID: editingID)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(STColor.background)
            .environment(\.stTheme, harness.model.theme)
            .environment(\.stSoundPlayer, STSoundPlayer.silent),
            size: size)
    }

    /// Bare keys, a duplicate, a placement with Show on Keyboard and a caution, then the same list with Advanced and
    /// an editor open.
    @Test func everyRowStateAndTheEditorRender() {
        let harness = Harness(accessibility: .granted)
        let advisor = FakeKeyboardAdvisor()
        advisor.placementText = "On Caps Lock"
        advisor.cautions = ["Minecraft uses F3 for Debug screen. While hotkeys are on, it never gets F3."]
        harness.model.hotkeys.advisor = advisor
        harness.model.hotkeys.isEnabled = true
        let pad = harness.model.hotkeys.add(combo: pad1, actions: [.toggle(.crosshair), .toggle(.nbbOverlay)])
        harness.model.hotkeys.add(combo: pad1, actions: [.startStopRecording])
        harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 99, modifiers: []), actions: [.toggle(.windowBackdrop)])

        let list = render(harness)
        let open = render(harness, advancedIsOpen: true, editingID: pad)
        #expect(distinctColors(in: list) > 20)
        #expect(distinctColors(in: open) > 20)
        #expect(list.representation(using: .png, properties: [:]) != open.representation(using: .png, properties: [:]))
    }

    /// The placement caption with Show on Keyboard, then a caution, each draw under the row.
    @Test func theKeyRebindersAdviceDrawsUnderARow() {
        let harness = Harness(accessibility: .granted)
        let advisor = FakeKeyboardAdvisor()
        defer { withExtendedLifetime(advisor) {} }
        harness.model.hotkeys.isEnabled = true
        harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 99, modifiers: []), actions: [.toggle(.windowBackdrop)])
        func png() -> Data? { render(harness).representation(using: .png, properties: [:]) }
        let plain = png()
        harness.model.hotkeys.advisor = advisor
        #expect(png() == plain)
        advisor.placementText = "On Caps Lock"
        let placed = png()
        advisor.cautions = ["Minecraft uses F3 for Debug screen. While hotkeys are on, it never gets F3."]
        let cautioned = png()
        #expect(Set([plain, placed, cautioned]).count == 3)
    }

    @Test func homeNoLongerSaysHotkeysPauseInFront() {
        let harness = Harness(accessibility: .granted)
        harness.model.hotkeys.isEnabled = true
        let before = render(harness)
        harness.model.hotkeys.setPaused(true, for: .recordingKey)
        let typing = render(harness)
        // Nothing on Home depends on a pause any more.
        #expect(before.representation(using: .png, properties: [:]) == typing.representation(using: .png, properties: [:]))
    }
}

/// The Key Rebinder's Open Hotkeys lands on Home's Hotkeys section, not the top of Home, even with Home open.
@MainActor
@Suite("Open Hotkeys")
struct OpenHotkeysTests {
    @Test func opensHomeAtItsHotkeys() {
        let harness = Harness(accessibility: .granted)
        harness.model.navigate(to: .tool(.keyRebinder))
        harness.model.openHotkeys()
        #expect(harness.model.route == .home)
        #expect(harness.model.pendingPageAnchor == .hotkeys)
    }

    @Test func scrollsHomeEvenWhenItIsAlreadyOpen() {
        let harness = Harness(accessibility: .granted)
        #expect(harness.model.route == .home)
        harness.model.openHotkeys()
        #expect(harness.model.pendingPageAnchor == .hotkeys)
    }

    @Test func theKeyRebindersButtonOpensHotkeysAndTheTrialHasNone() {
        let harness = Harness(accessibility: .granted)
        ToolContent(model: harness.model, tool: .keyRebinder).openHotkeys?()
        #expect(harness.model.pendingPageAnchor == .hotkeys)
        #expect(ToolContent(model: harness.model, tool: .keyRebinder, isTrial: true).openHotkeys == nil)
    }
}
