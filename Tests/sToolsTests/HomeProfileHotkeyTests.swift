import AppKit
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])
private let f7 = HotkeyCombo(keyCode: 98, modifiers: [])
private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])
private let minecraft = HotkeyAction.profile(.select("Minecraft"))

/// "⌘1 Crosshair", as the Hotkeys page lists a hotkey.
@MainActor
private func listing(_ hotkeys: HotkeyCenter) -> [String] {
    hotkeys.bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
}

/// Stands in for the Key Rebinder: the profiles it hands over, and how often it was asked to read them again.
@MainActor
private final class ProfilesAdvisor: HotkeyAdvising {
    var profiles: HotkeyProfiles
    private(set) var refreshes = 0

    init(_ profiles: HotkeyProfiles) { self.profiles = profiles }

    func notes(for combo: HotkeyCombo) -> [HotkeyNote] { [] }
    func placement(of combo: HotkeyCombo) -> HotkeyPlacement? { nil }
    func selectKey(for combo: HotkeyCombo) -> Bool { false }
    func prepareAdvice() async {}
    func refreshProfiles() async { refreshes += 1 }
}

private let ready = HotkeyProfiles(state: .ready, names: ["Default profile", "Minecraft", "Typing"], current: "Default profile")

/// The Hotkeys page with Karabiner profiles (spec 6.1): the editor saves the profile row's choice with the chips', a
/// profile has one key of its own, and a row says when its profile can't be switched to.
@MainActor
@Suite("Hotkeys page profile hotkeys")
struct HomeProfileHotkeyTests {
    @Test func theEditorSavesTheProfileAfterTheTools() {
        let harness = Harness(hotkeys: nil)
        let hotkeys = harness.model.hotkeys
        #expect(HotkeyEditor.save(ctrlOptC, actions: [minecraft, .toggle(.windowBackdrop), .toggle(.crosshair)], existing: nil,
                                  in: hotkeys) == .saved)
        #expect(HotkeyEditor.save(f6, actions: [.profile(.next)], existing: nil, in: hotkeys) == .saved)
        #expect(listing(hotkeys) == ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop",
                                     "⌃⌥C Crosshair + Window Backdrop + Switch to Minecraft", "F6 Next profile"])
        // Editing a hotkey with None in the profile row takes its profile off.
        let custom = hotkeys.bindings[5]
        #expect(HotkeyEditor.save(ctrlOptC, actions: [.toggle(.crosshair), .toggle(.windowBackdrop)], existing: custom,
                                  in: hotkeys) == .saved)
        #expect(hotkeys.bindings.first { $0.id == custom.id }?.actions == [.toggle(.crosshair), .toggle(.windowBackdrop)])
    }

    /// A profile has one key of its own, as a tool does: a second key for it alone asks first, and Replace keeps one row.
    @Test func aSecondKeyForAProfileAsksAndReplaceKeepsOneRow() throws {
        let harness = Harness(hotkeys: nil)
        let hotkeys = harness.model.hotkeys
        #expect(HotkeyEditor.save(f6, actions: [minecraft], existing: nil, in: hotkeys) == .saved)
        let own = try #require(hotkeys.profileHotkey(for: "Minecraft"))
        #expect(HotkeyEditor.save(f7, actions: [minecraft], existing: nil, in: hotkeys) == .asksToReplace(own))
        #expect(HotkeyWording.replaceOwnKeyQuestion(own, with: f7) == "Use F7 to switch to Minecraft?")
        HotkeyEditor.replace(own, with: f7, editing: nil, in: hotkeys)
        #expect(hotkeys.hotkeys(switchingTo: "Minecraft").map(\.combo) == [f7])
        #expect(listing(hotkeys).last == "F7 Switch to Minecraft")
    }

    /// A row says what keeps its profile from switching: a profile Karabiner-Elements no longer lists, or why no profile
    /// can be switched to. Its key's own problem comes first.
    @Test func aRowSaysWhenItsProfileCantBeSwitchedTo() throws {
        let harness = Harness(hotkeys: nil)
        let hotkeys = harness.model.hotkeys
        hotkeys.isEnabled = true
        let advisor = ProfilesAdvisor(ready)
        hotkeys.advisor = advisor
        let gone = hotkeys.add(combo: f6, actions: [.profile(.select("Speedrun"))])
        let fine = hotkeys.add(combo: f7, actions: [.toggle(.crosshair), minecraft])
        let row = { (id: UUID) in try #require(hotkeys.bindings.first { $0.id == id }) }
        #expect(HotkeyBindingRow.statusNote(for: try row(gone), in: hotkeys) == "No profile named \u{201C}Speedrun\u{201D}")
        #expect(HotkeyBindingRow.statusNote(for: try row(fine), in: hotkeys) == nil)

        advisor.profiles = HotkeyProfiles(state: .unavailable(.notRunning))
        #expect(HotkeyBindingRow.statusNote(for: try row(fine), in: hotkeys) == "Karabiner-Elements isn\u{2019}t running")
        // Before the profiles are read, nothing is said.
        advisor.profiles = .unknown
        #expect(HotkeyBindingRow.statusNote(for: try row(gone), in: hotkeys) == nil)
        // A duplicate key says so first.
        advisor.profiles = ready
        let duplicate = hotkeys.add(combo: f6, actions: [.profile(.select("Speedrun"))])
        #expect(HotkeyBindingRow.statusNote(for: try row(duplicate), in: hotkeys) == "Already used above")
        withExtendedLifetime(advisor) {}
    }

    /// Without a Key Rebinder there is no Karabiner-Elements, and a profile hotkey's row says so.
    @Test func withoutAKeyRebinderTheRowSaysKarabinerIsntThere() {
        let harness = Harness(hotkeys: nil)
        let id = harness.model.hotkeys.add(combo: f6, actions: [minecraft])
        let binding = harness.model.hotkeys.bindings.first { $0.id == id }
        #expect(binding.flatMap { HotkeyBindingRow.statusNote(for: $0, in: harness.model.hotkeys) }
            == "Karabiner-Elements isn\u{2019}t installed")
    }

    /// The editor reads the profiles again as it opens, so its row lists them as they are now.
    @Test func openingTheEditorReadsTheProfiles() async {
        let harness = Harness(hotkeys: nil)
        let advisor = ProfilesAdvisor(ready)
        harness.model.hotkeys.advisor = advisor
        let host = NSHostingView(rootView: HotkeyEditor(model: harness.model, existing: nil, onDone: {})
            .frame(width: 600, height: 400, alignment: .topLeading)
            .environment(\.stTheme, harness.model.theme)
            .environment(\.stSoundPlayer, STSoundPlayer.silent))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        #expect(await waitUntil {
            host.layoutSubtreeIfNeeded()
            return advisor.refreshes >= 1
        })
        withExtendedLifetime(host) {}
    }

    /// The editor draws the profile row under the chips, and the row's note in its place while there is nothing to choose.
    @Test func theEditorDrawsTheProfileRow() {
        let harness = Harness(hotkeys: nil)
        let advisor = ProfilesAdvisor(ready)
        harness.model.hotkeys.advisor = advisor
        let id = harness.model.hotkeys.add(combo: ctrlOptC, actions: [.toggle(.crosshair), minecraft])
        let existing = harness.model.hotkeys.bindings.first { $0.id == id }
        func render() -> NSBitmapImageRep {
            renderBitmap(
                HotkeyEditor(model: harness.model, existing: existing, onDone: {})
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(STColor.background)
                    .environment(\.stTheme, harness.model.theme)
                    .environment(\.stSoundPlayer, STSoundPlayer.silent),
                size: CGSize(width: 640, height: 320))
        }
        let withProfiles = render()
        advisor.profiles = HotkeyProfiles(state: .unavailable(.notRunning))
        let notRunning = render()
        #expect(distinctColors(in: withProfiles) > 20)
        #expect(withProfiles.representation(using: .png, properties: [:]) != notRunning.representation(using: .png, properties: [:]))
    }
}
