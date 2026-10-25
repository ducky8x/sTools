import AppKit
import Foundation
import KeyRebinder
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

private let keypad1 = HotkeyCombo(keyCode: 83, modifiers: [])
private let f3 = HotkeyCombo(keyCode: 99, modifiers: [])
private let f20 = HotkeyCombo(keyCode: 90, modifiers: [])

/// `karabiner.json` with one selected profile, "P", holding these key-to-key Simple Modifications.
private func karabinerJSON(_ rebinds: [(from: String, to: String)]) -> String {
    let simple = rebinds.map { #"{ "from": { "key_code": "\#($0.from)" }, "to": [{ "key_code": "\#($0.to)" }] }"# }
    return #"{ "profiles": [{ "name": "P", "selected": true, "simple_modifications": [\#(simple.joined(separator: ", "))] }] }"#
}

/// The app wires its one hotkey list into the Key Rebinder (spec 5.5.2, 5.5.3, 6.1), which then shows and edits it
/// on the keys and advises Home on it.
@MainActor
@Suite("AppModel and the Key Rebinder")
struct AppModelKeyRebinderTests {
    @Test func theKeyRebinderShowsTheAppsHotkeyListAndAdvisesOnIt() throws {
        let harness = Harness(withKeyRebinder: true)
        let keyRebinder = try #require(harness.model.keyRebinder)
        #expect(keyRebinder.hotkeyCenter === harness.model.hotkeys)
        #expect(harness.model.hotkeys.advisor === keyRebinder)
    }

    @Test func withoutAKeyRebinderHomeHasNoAdvisor() {
        let harness = Harness()
        #expect(harness.model.keyRebinder == nil)
        #expect(harness.model.hotkeys.advisor == nil)
    }

    @Test func aHotkeySavedOnTheKeyboardJoinsHomesList() throws {
        let harness = Harness(withKeyRebinder: true)
        let keyRebinder = try #require(harness.model.keyRebinder)
        keyRebinder.chooseLayout(shape: .ansi, formFactor: .fullSize)
        let id = try #require(keyRebinder.saveHotkey(on: .key("keypad_1"), editing: nil, modifiers: [], actions: [.toggle(.crosshair)]))
        #expect(harness.model.hotkeys.bindings.map(\.id) == [id])
        #expect(harness.model.hotkeys.bindings.first?.combo == keypad1)
        #expect(harness.model.hotkeys.bindings.first?.actions == [.toggle(.crosshair)])
    }

    @Test func showOnKeyboardSelectsTheKeyAndOpensTheKeyRebinder() throws {
        let harness = Harness(withKeyRebinder: true)
        let keyRebinder = try #require(harness.model.keyRebinder)
        // A laptop keyboard has no keypad, so nothing sends Pad 1 and the page stays as it was.
        keyRebinder.chooseLayout(shape: .ansi, formFactor: .laptop)
        #expect(!harness.model.showHotkeyOnKeyboard(keypad1))
        #expect(keyRebinder.selectedKey == nil)
        #expect(harness.model.route == .home)

        keyRebinder.chooseLayout(shape: .ansi, formFactor: .fullSize)
        #expect(harness.model.showHotkeyOnKeyboard(keypad1))
        #expect(keyRebinder.selectedKey == .key("keypad_1"))
        #expect(harness.model.route == .tool(.keyRebinder))
        #expect(harness.model.pendingPageAnchor == .keyRebinderKeyPanel, "the page scrolls to the key's panel")
    }

    @Test func homesPlacementComesFromTheKeyRebinder() async throws {
        let harness = Harness(withKeyRebinder: true)
        try Data(karabinerJSON([("caps_lock", "f20")]).utf8).write(to: harness.karabinerConfigURL)
        let keyRebinder = try #require(harness.model.keyRebinder)
        keyRebinder.chooseLayout(shape: .ansi, formFactor: .laptop)
        harness.model.hotkeys.isEnabled = true
        harness.model.hotkeys.add(combo: f20, actions: [.toggle(.nbbOverlay)])
        // What Home ▸ Hotkeys runs when it appears: it reads karabiner.json, and never runs karabiner_cli.
        await harness.model.hotkeys.advisor?.prepareAdvice()
        #expect(keyRebinder.config != nil)
        #expect(harness.model.hotkeys.advisor?.placement(of: f20) == HotkeyPlacement(text: "On Caps Lock", canShow: true))
        #expect(harness.model.showHotkeyOnKeyboard(f20))
        #expect(keyRebinder.selectedKey == .key("caps_lock"))
    }
}

/// The Key Rebinder's page and its Prologue trial (spec 4, 5.5): the page shows sTools hotkeys, the trial none.
@MainActor
@Suite("Key Rebinder page and trial", .serialized)
struct KeyRebinderTrialTests {
    init() { STFont.register() }

    /// The view as PNG data, rendered offscreen at 1x with no window.
    private func png(_ view: some View, _ harness: Harness) -> Data? {
        renderBitmap(
            view
                .environment(\.stTheme, harness.model.theme)
                .environment(\.stSoundPlayer, STSoundPlayer.silent)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(STColor.background),
            size: CGSize(width: 1200, height: 1500)
        ).representation(using: .png, properties: [:])
    }

    @Test func openHotkeysOpensHomeOnThePageAndIsLeftOutOfTheTrial() throws {
        let harness = Harness(withKeyRebinder: true)
        harness.model.navigate(to: .tool(.keyRebinder))
        #expect(ToolContent(model: harness.model, tool: .keyRebinder, isTrial: true).openHotkeys == nil)
        let open = try #require(ToolContent(model: harness.model, tool: .keyRebinder).openHotkeys)
        open()
        #expect(harness.model.route == .home)
    }

    /// With hotkeys on, F3 alone wears a ring and has a finding with its red dot, its panel lists it, and Pad 1 is
    /// listed as sent by no key on a laptop keyboard: all of it on the page, none of it in the trial.
    @Test func theTrialShowsNoneOfTheHotkeyParts() async throws {
        let harness = Harness(withKeyRebinder: true)
        let keyRebinder = try #require(harness.model.keyRebinder)
        await keyRebinder.refresh()
        keyRebinder.chooseLayout(shape: .ansi, formFactor: .laptop)
        keyRebinder.selectedKey = .key("f3")
        let trialBefore = png(TrialToolControls(model: harness.model, tool: .keyRebinder), harness)
        let pageBefore = png(ToolContent(model: harness.model, tool: .keyRebinder), harness)

        harness.model.hotkeys.isEnabled = true
        harness.model.hotkeys.add(combo: f3, actions: [.toggle(.crosshair)])
        harness.model.hotkeys.add(combo: keypad1, actions: [.toggle(.nbbOverlay)])
        #expect(await waitUntil { keyRebinder.hotkeyMark(for: .key("f3")) == .working })
        #expect(keyRebinder.hotkeyFindings(for: .key("f3")).count == 1)
        #expect(keyRebinder.unplacedHotkeysText != nil)

        #expect(trialBefore != nil)
        #expect(png(TrialToolControls(model: harness.model, tool: .keyRebinder), harness) == trialBefore)
        #expect(png(ToolContent(model: harness.model, tool: .keyRebinder), harness) != pageBefore)
    }
}
