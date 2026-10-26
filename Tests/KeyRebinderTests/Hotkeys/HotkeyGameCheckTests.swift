import Testing
@testable import KeyRebinder
import STPlatform

@Suite struct HotkeyGameCheckTests {
    let options = HotkeyFixtures.options1161

    private func caution(
        _ code: String, _ modifiers: HotkeyCombo.Modifiers = [], with keybinds: [MinecraftKeybind]?
    ) -> HotkeyGameCaution? {
        HotkeyGameCheck.caution(for: HotkeyFixtures.combo(code, modifiers), minecraftKeybinds: keybinds)
    }

    // MARK: Uses a hotkey takes

    @Test func bareF3TakesTheDebugScreen() throws {
        for keybinds in [options, nil] {
            let found = try #require(caution("f3", with: keybinds))
            #expect(found.uses.map(\.description) == ["Debug screen"])
            #expect(found.key == .key("f3"))
            #expect(found.heldActions.isEmpty)
        }
    }

    @Test func bareEscTakesThePauseMenu() throws {
        let found = try #require(caution("escape", with: options))
        #expect(found.uses.map(\.description).contains("Pause menu"))
    }

    @Test func bareCTakesSaveHotbarAndF3C() throws {
        let found = try #require(caution("c", with: options))
        #expect(found.uses.map(\.description) == ["Save hotbar", "F3+C (copies your position for Ninjabrain Bot)"])
        #expect(!found.usesDefaults)
        #expect(found.text == "Minecraft uses C for Save hotbar and F3+C (copies your position for Ninjabrain Bot). While hotkeys are on, it never gets C.")
        let byDefault = try #require(caution("c", with: nil))
        #expect(byDefault.usesDefaults)
        #expect(byDefault.text.contains("by default"))
    }

    @Test func shiftF3TakesThePieChart() throws {
        let found = try #require(caution("f3", .shift, with: options))
        #expect(found.uses.map(\.description).contains("the pie chart"))
        #expect(found.text.hasPrefix("Minecraft uses \u{21E7}F3 for the pie chart."))
    }

    @Test func aKeypadKeyBoundToAHotbarSlotIsTaken() throws {
        let keybinds = HotkeyFixtures.keybinds("key_key.hotbar.1:key.keyboard.keypad.1")
        let found = try #require(caution("keypad_1", with: keybinds))
        #expect(found.uses.map(\.description) == ["Hotbar 1"])
    }

    @Test func bareReturnTakesChat() throws {
        let found = try #require(caution("return_or_enter", with: options))
        #expect(found.uses.map(\.description).contains { $0.contains("chat") })
        #expect(caution("keypad_enter", with: options)?.uses.map(\.description).contains { $0.contains("chat") } == true)
    }

    @Test func bareQTakesDropItemByDefault() throws {
        let found = try #require(caution("q", with: nil))
        #expect(found.text.contains("Drop item by default"))
        #expect(found.usesDefaults)
    }

    @Test func bareF13IsFree() {
        #expect(caution("f13", with: options) == nil)
        #expect(caution("f13", with: nil) == nil)
    }

    // MARK: Held modifiers

    @Test func shiftWIsTakenWhileSneaking() throws {
        let found = try #require(caution("w", .shift, with: options))
        #expect(found.uses.map(\.description) == ["Forward"])
        #expect(found.heldActions == ["Sneak"])
        #expect(found.text == "Minecraft uses W for Forward, and Shift for Sneak: pressing W while holding Shift fires this hotkey instead.")
    }

    @Test func controlWIsTakenWhileSprinting() throws {
        let found = try #require(caution("w", .control, with: options))
        #expect(found.heldActions == ["Sprint"])
    }

    @Test func aModifierMinecraftDoesNotBindKeepsTheKeyFree() {
        #expect(caution("e", [.control, .option], with: options) == nil)
        #expect(caution("w", .command, with: options) == nil)
    }

    @Test func theF3TextIsExact() throws {
        let found = try #require(caution("f3", with: options))
        #expect(found.text == "Minecraft uses F3 for Debug screen. While hotkeys are on, it never gets F3.")
    }

    @Test func atMostTwoUsesAreNamed() throws {
        let keybinds = HotkeyFixtures.keybinds("""
            key_key.drop:key.keyboard.b
            key_key.inventory:key.keyboard.b
            key_key.chat:key.keyboard.b
            """)
        let found = try #require(caution("b", with: keybinds))
        #expect(found.uses.count == 4)
        #expect(found.text == "Minecraft uses B for Drop item, Inventory and more. While hotkeys are on, it never gets B.")
    }

    @Test func heldModifierNoteNamesTheModifiersMinecraftBinds() throws {
        let note = try #require(HotkeyGameCheck.heldModifierNote(for: HotkeyFixtures.combo("f18"), minecraftKeybinds: nil))
        #expect(note.contains("Shift (Sneak)"))
        #expect(note.contains("Control (Sprint)"))
        #expect(note.hasPrefix("F18 won\u{2019}t fire while you hold Shift (Sneak) or Control (Sprint)"))
        #expect(HotkeyGameCheck.heldModifierNote(for: HotkeyFixtures.combo("f18", [.control, .shift]), minecraftKeybinds: nil) == nil)
        let known = HotkeyGameCheck.heldModifierNote(for: HotkeyFixtures.combo("f18", .control), minecraftKeybinds: options)
        #expect(known == "\u{2303}F18 won\u{2019}t fire while you hold Shift (Sneak).")
    }

    @Test func noHeldModifierNoteWhenMinecraftBindsNoModifier() {
        let keybinds = HotkeyFixtures.keybinds("key_key.sneak:key.keyboard.c\nkey_key.sprint:key.keyboard.v")
        #expect(HotkeyGameCheck.heldModifierNote(for: HotkeyFixtures.combo("f18"), minecraftKeybinds: keybinds) == nil)
    }

    // MARK: What Minecraft uses

    @Test func theDefaultsAreMinecraft1161s() {
        var defaults: [KarabinerEvent: [String]] = [:]
        for keybind in HotkeyGameCheck.defaultKeybinds {
            guard let event = keybind.event else { continue }
            defaults[event, default: []].append(keybind.display)
        }
        #expect(defaults[.key("w")] == ["Forward"])
        #expect(defaults[.key("left_shift")] == ["Sneak"])
        #expect(defaults[.key("left_control")] == ["Sprint"])
        #expect(defaults[.key("f")] == ["Swap hands"])
        #expect(defaults[.key("f3")] == ["Debug screen"])
        #expect(defaults[.key("escape")] == ["Pause menu"])
        #expect(defaults[.key("f11")] == ["Fullscreen"])
        #expect(defaults[.key("9")] == ["Hotbar 9"])
        #expect(defaults[.pointing("button3")] == ["Pick block"])
        #expect(defaults[.key("c")] == ["Save hotbar"])
    }

    @Test func gameKeysComeFromTheKeybindsOrTheDefaults() {
        let custom = HotkeyGameCheck.gameKeys(minecraftKeybinds: HotkeyFixtures.keybinds("key_key.sneak:key.keyboard.left.alt"))
        #expect(custom.contains(.key("left_option")))
        #expect(!custom.contains(.key("left_shift")))
        let defaults = HotkeyGameCheck.gameKeys(minecraftKeybinds: nil)
        #expect(defaults.contains(.key("left_shift")))
        #expect(defaults.contains(.pointing("button3")))
        #expect(!defaults.contains(.key("f20")))
    }

    @Test func theHardWiredUsesAreMinecraft1161s() {
        let keys = HotkeyGameCheck.hardWired.filter { $0.modifiers.isEmpty }.map(\.key)
        let letters = ["a", "b", "c", "d", "g", "h", "i", "n", "p", "q", "t"].map(KarabinerEvent.key)
        #expect(keys == letters + [.key("f4"), .key("escape"), .key("return_or_enter"), .key("keypad_enter")])
        #expect(HotkeyGameCheck.hardWired.filter { !$0.modifiers.isEmpty }.map(\.modifiers) == [.shift, .option])
    }
}
