import Testing
@testable import Crosshair

/// The Crosshair page's switches for Minecraft's menus: their words, and when the hide switch can be changed.
@MainActor
@Suite("Crosshair: the menu switches on the page")
struct CrosshairMenuRowsTests {
    typealias Copy = CrosshairMenuRows.Copy

    @Test func theirWords() {
        #expect(Copy.hideLabel == "Hide in Minecraft\u{2019}s menus")
        #expect(Copy.hideCaption == "Hides the crosshair while Minecraft shows the pointer: in menus, inventories and the pause screen.")
        #expect(Copy.hideWhilePointer == "Always on while the crosshair is the pointer.")
        #expect(Copy.pointerLabel == "Be the pointer in Minecraft\u{2019}s menus")
        #expect(Copy.pointerCaption == "In menus, the pointer looks like the crosshair and clicks where it aims.")
        #expect(Copy.otherApps == "When sTools puts your arrow back, it can also reset pointers another cursor app such as Mousecape "
            + "changed. Apply them again from that app.")
        #expect(Copy.cantWatch == "This version of macOS doesn\u{2019}t say when Minecraft shows the pointer, so these do nothing.")
        #expect(Copy.cantSwap == "This version of macOS doesn\u{2019}t let sTools change the pointer.")
    }

    /// While the crosshair is the pointer, the hide switch shows on, can't be changed, and its line says why.
    @Test func beingThePointerHoldsTheHideSwitchOn() {
        #expect(CrosshairMenuRows.hideIsEditable(canWatch: true, isPointer: false))
        #expect(!CrosshairMenuRows.hideIsEditable(canWatch: true, isPointer: true))
        #expect(!CrosshairMenuRows.hideIsEditable(canWatch: false, isPointer: false))
        #expect(CrosshairMenuRows.hideLine(isPointer: false) == Copy.hideCaption)
        #expect(CrosshairMenuRows.hideLine(isPointer: true) == Copy.hideWhilePointer)
    }

    @Test func thePointerSwitchsLines() {
        #expect(CrosshairMenuRows.pointerLines(canWatch: true, canSwap: true) == [Copy.pointerCaption, Copy.otherApps])
        #expect(CrosshairMenuRows.pointerLines(canWatch: true, canSwap: false) == [Copy.pointerCaption, Copy.cantSwap])
        #expect(CrosshairMenuRows.pointerLines(canWatch: false, canSwap: false) == [Copy.pointerCaption, Copy.cantWatch])
    }
}
