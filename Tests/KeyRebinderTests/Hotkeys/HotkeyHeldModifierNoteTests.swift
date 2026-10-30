import Testing
@testable import KeyRebinder
import STPlatform

// "F18 won’t fire while you hold Shift (Sneak) or Control (Sprint)" is true only while a hotkey fires exactly as set.
// With Also fire while holding Shift or Control on (spec 6.1, revision 45) it also fires with those held, so the
// note leaves them out and shows only for another modifier Minecraft binds.

@Suite struct HotkeyHeldModifierNoteTests {
    private let f18 = HotkeyFixtures.combo("f18")

    @Test func theNoteIsGoneWhenTheVariantsCoverEveryModifierMinecraftBinds() {
        // Minecraft 1.16.1's defaults bind Shift (Sneak) and Control (Sprint).
        #expect(HotkeyGameCheck.heldModifierNote(for: f18, minecraftKeybinds: nil, alsoFiringWith: [.shift, .control]) == nil)
        #expect(HotkeyGameCheck.heldModifierNote(for: f18, minecraftKeybinds: HotkeyFixtures.options1161,
                                                 alsoFiringWith: [.shift, .control]) == nil)
    }

    @Test func theNoteIsAsItWasWhenTheVariantsAreOff() throws {
        let off = try #require(HotkeyGameCheck.heldModifierNote(for: f18, minecraftKeybinds: nil, alsoFiringWith: []))
        #expect(off == HotkeyGameCheck.heldModifierNote(for: f18, minecraftKeybinds: nil))
        #expect(off.hasPrefix("F18 won\u{2019}t fire while you hold Shift (Sneak) or Control (Sprint)"))
    }

    @Test func aModifierTheVariantsDontCoverKeepsItsNote() throws {
        let keybinds = HotkeyFixtures.keybinds("key_key.sneak:key.keyboard.left.shift\nkey_key.drop:key.keyboard.left.alt")
        let both = try #require(HotkeyGameCheck.heldModifierNote(for: f18, minecraftKeybinds: keybinds))
        #expect(both == "F18 won\u{2019}t fire while you hold Shift (Sneak) or Option (Drop item).")
        let option = try #require(HotkeyGameCheck.heldModifierNote(for: f18, minecraftKeybinds: keybinds, alsoFiringWith: [.shift, .control]))
        #expect(option == "F18 won\u{2019}t fire while you hold Option (Drop item).")
    }

    @Test func aModifierTheHotkeyHoldsAlreadyIsStillLeftOut() throws {
        let keybinds = HotkeyFixtures.keybinds("key_key.sneak:key.keyboard.left.shift\nkey_key.drop:key.keyboard.left.alt")
        let withOption = HotkeyFixtures.combo("f18", .option)
        #expect(HotkeyGameCheck.heldModifierNote(for: withOption, minecraftKeybinds: keybinds, alsoFiringWith: [.shift, .control]) == nil)
    }
}
