import AppKit
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

private let pad1 = HotkeyCombo(keyCode: 83, modifiers: [])

/// Home ▸ Hotkeys sits near the top of Home and shows its list whether hotkeys are on or off.
@MainActor
@Suite("Home hotkeys at a glance")
struct HomeHotkeysGlanceTests {
    @Test func whileOffOneStripSaysSoAndTheListStillShows() {
        #expect(HotkeysSection.offMessage(hasHotkeys: false, scope: .sToolsAndMinecraft)
            == "Hotkeys are off. Turn them on to switch tools with a key, in sTools and Minecraft.")
        #expect(HotkeysSection.offMessage(hasHotkeys: false, scope: .everywhere)
            == "Hotkeys are off. Turn them on to switch tools with a key, from any app.")
        #expect(HotkeysSection.offMessage(hasHotkeys: true, scope: .sToolsAndMinecraft) == "Hotkeys are off, so the keys below do nothing.")

        let harness = Harness(accessibility: .granted)
        func png() -> Data? { render(harness).representation(using: .png, properties: [:]) }
        let none = png()
        harness.model.hotkeys.add(combo: pad1, actions: [.toggle(.crosshair)])
        let listedWhileOff = png()
        harness.model.hotkeys.isEnabled = true
        let listedWhileOn = png()
        #expect(Set([none, listedWhileOff, listedWhileOn]).count == 3)
    }

    /// Where hotkeys work shows its choice, and says why hotkeys work only in sTools until Accessibility is allowed.
    @Test func whereHotkeysWorkShowsItsChoice() {
        #expect(HotkeysSection.scopeNote(scope: .sToolsAndMinecraft, accessibilityGranted: true) == nil)
        #expect(HotkeysSection.scopeNote(scope: .everywhere, accessibilityGranted: false) == nil)
        #expect(HotkeysSection.scopeNote(scope: .sToolsAndMinecraft, accessibilityGranted: false)
            == "Until Accessibility is allowed, sTools can't tell when Minecraft is in front, so hotkeys work only in sTools.")

        let harness = Harness(accessibility: .granted)
        #expect(harness.model.hotkeys.scope == .sToolsAndMinecraft)
        let sToolsAndMinecraft = render(harness).representation(using: .png, properties: [:])
        harness.model.hotkeys.scope = .everywhere
        let everywhere = render(harness).representation(using: .png, properties: [:])
        #expect(sToolsAndMinecraft != everywhere)
        #expect(Harness(accessibility: .denied).model.hotkeys.scope == .sToolsAndMinecraft)
    }

    private func render(_ harness: Harness) -> NSBitmapImageRep {
        renderBitmap(
            VStack(alignment: .leading, spacing: 0) {
                HotkeysSection(model: harness.model)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(STColor.background)
            .environment(\.stTheme, harness.model.theme)
            .environment(\.stSoundPlayer, STSoundPlayer.silent),
            size: CGSize(width: 640, height: 400))
    }
}
