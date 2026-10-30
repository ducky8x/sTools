import AppKit
import Foundation
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

// Also fire while holding Shift or Control (spec 6.1, revision 45) in the app: the Go menu's shortcuts are the ones no
// variant takes, the option sits in Home ▸ Hotkeys ▸ Advanced, and it is its own setting that export, import, Reset and
// Copy Diagnostics carry. The app tests' harness starts with the option off (so the fake registrar holds just the list);
// each test here turns it on.

@MainActor
@Suite("Hotkeys also firing with Shift or Control, in the app")
struct HotkeyHeldModifierAppTests {
    private func combo(_ character: Character, _ modifiers: HotkeyCombo.Modifiers) -> HotkeyCombo {
        HotkeyCombo(character: character, modifiers: modifiers)!
    }

    // MARK: The Go menu's shortcuts

    @Test func theGoMenusShortcutsAreTheOnesNoVariantTakes() {
        let shortcuts = GoCommand.menuShortcuts
        #expect(shortcuts.count == GoCommand.menu.count, "every item has its own")
        for digit in "0123456" {
            #expect(shortcuts.contains(combo(digit, [.control, .command])), "⌃⌘\(digit)")
        }
        #expect(shortcuts.isSuperset(of: [combo(",", .command), combo("[", .command), combo("]", .command)]))
        #expect(GoCommand.home.shortcutCombo?.displayString == "⌃⌘0")
        #expect(GoCommand.tool(.nbbOverlay).shortcutCombo?.displayString == "⌃⌘3")
        #expect(GoCommand.settings.shortcutCombo?.displayString == "⌘,")
    }

    @Test func aNewInstallsKeysKeepTheirVariantsExceptWhereTheMenuOrMacOSHasThem() throws {
        let harness = Harness(accessibility: .granted, hotkeys: nil)
        let hotkeys = harness.model.hotkeys // the center starts when it is first used
        let fake = try #require(harness.hotkeyRegistrar as? FakeHotkeyRegistrar)
        #expect(Set(fake.registered.values) == Set(HotkeyKeySet.command.combos), "off in the harness: just the list")

        hotkeys.alsoFiresWithShiftOrControl = true
        let live = Set(fake.registered.values)
        #expect(live.isSuperset(of: HotkeyKeySet.command.combos))
        #expect(live.isDisjoint(with: GoCommand.menuShortcuts), "with sTools in front, ⌘1 with Control held is ⌃⌘1, the Go menu's")
        #expect(live.contains(combo("1", [.shift, .command])) && live.contains(combo("2", [.shift, .control, .command])))
        #expect(!live.contains(combo("3", [.shift, .command])), "⇧⌘3 is macOS's screenshot")
        #expect(!live.contains(combo("4", [.shift, .control, .command])), "⌃⇧⌘4 is macOS's screenshot to the clipboard")

        // In the game there is no sTools menu: each ⌘ key also fires with Control held.
        hotkeys.setFrontApp(.minecraft)
        let inTheGame = Set(fake.registered.values)
        for digit in "12345" { #expect(inTheGame.contains(combo(digit, [.control, .command])), "⌃⌘\(digit)") }
        #expect(!inTheGame.contains(combo("3", [.shift, .command])), "macOS's screenshot is macOS's everywhere")
        hotkeys.setFrontApp(.sTools)
        #expect(Set(fake.registered.values).isDisjoint(with: GoCommand.menuShortcuts))
        // Not one hotkey of the list moved: the variants exist only in what is registered.
        #expect(hotkeys.bindings.map(\.combo) == HotkeyKeySet.command.combos)
    }

    // MARK: Home ▸ Hotkeys ▸ Advanced

    @Test func theOptionIsNamedAsTheSpecNamesIt() {
        #expect(HotkeysSection.alsoFireLabel == "Also fire while holding Shift or Control")
        #expect(HotkeysSection.alsoFireNote
            == "Skips a combination that another hotkey or macOS already uses, such as \u{21E7}\u{2318}3, and sTools\u{2019} own menu shortcuts while it is in front.")
    }

    @Test func advancedDrawsTheOptionAndItsNoteOnlyWhileItIsOn() {
        let harness = Harness(accessibility: .granted)
        harness.model.hotkeys.isEnabled = true
        func png(open: Bool) -> Data? {
            renderBitmap(
                VStack(alignment: .leading, spacing: 0) { HotkeysSection(model: harness.model, advancedIsOpen: open) }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(STColor.background)
                    .environment(\.stTheme, harness.model.theme)
                    .environment(\.stSoundPlayer, STSoundPlayer.silent),
                size: CGSize(width: 640, height: 720)).representation(using: .png, properties: [:])
        }
        harness.model.hotkeys.alsoFiresWithShiftOrControl = true
        let closed = png(open: false)
        let onAndOpen = png(open: true)
        harness.model.hotkeys.alsoFiresWithShiftOrControl = false
        let offAndOpen = png(open: true)
        #expect(Set([closed, onAndOpen, offAndOpen]).count == 3, "closed, open with the note, open without it")
    }

    // MARK: Its own setting

    @Test func theOptionIsCarriedByExportImportAndReset() async throws {
        let harness = Harness(accessibility: .granted)
        let directory = harness.directory
        let file = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).stools-settings")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AppModel.knownSettingsVersions[HotkeyHeldModifierSettings.name] == HotkeyHeldModifierSettings.version)

        harness.model.hotkeys.alsoFiresWithShiftOrControl = true
        let summary = try await harness.model.exportSettings(to: file)
        #expect(summary.documentNames.contains(HotkeyHeldModifierSettings.name), "export takes every document")

        harness.model.hotkeys.alsoFiresWithShiftOrControl = false
        await harness.model.settings.flush()
        let report = try await harness.model.importSettings(from: file)
        #expect(report.documents.first { $0.name == HotkeyHeldModifierSettings.name }?.outcome == .applied)
        #expect(SettingsStore(directory: directory).load(HotkeyHeldModifierSettings.self).alsoFiresWithShiftOrControl,
                "the imported choice is what is stored")

        let backup = try #require(try await harness.model.resetAppSettings())
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(HotkeyHeldModifierSettings.name).json").path))
        #expect(FileManager.default.fileExists(atPath: backup.appending(path: "\(HotkeyHeldModifierSettings.name).json").path),
                "Reset keeps it with the rest in its backup folder")
    }

    @Test func copyDiagnosticsSaysWhetherHotkeysAlsoFireWithShiftOrControl() {
        let harness = Harness(accessibility: .granted)
        let clipboard = FakeClipboard()
        func header() -> String { (clipboard.copiedText ?? "").components(separatedBy: "\n\n").first ?? "" }

        harness.model.copyDiagnostics(to: clipboard)
        #expect(header().contains("\nKey set: \(HotkeyKeySet.name(of: harness.model.hotkeys.keySet))\nAlso fires with Shift or Control: off"))
        harness.model.hotkeys.alsoFiresWithShiftOrControl = true
        harness.model.copyDiagnostics(to: clipboard)
        #expect(header().contains("\nAlso fires with Shift or Control: on"))
    }
}
