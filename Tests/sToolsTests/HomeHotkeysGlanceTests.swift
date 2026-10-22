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
        #expect(HotkeysSection.offMessage(hasHotkeys: false) == "Hotkeys are off. Turn them on to switch tools with a key, from any app.")
        #expect(HotkeysSection.offMessage(hasHotkeys: true) == "Hotkeys are off, so the keys below do nothing.")

        let harness = Harness(accessibility: .granted)
        func png() -> Data? { render(harness).representation(using: .png, properties: [:]) }
        let none = png()
        harness.model.hotkeys.add(combo: pad1, actions: [.toggle(.crosshair)])
        let listedWhileOff = png()
        harness.model.hotkeys.isEnabled = true
        let listedWhileOn = png()
        #expect(Set([none, listedWhileOff, listedWhileOn]).count == 3)
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
