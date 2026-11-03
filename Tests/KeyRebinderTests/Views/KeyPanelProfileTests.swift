import AppKit
import Foundation
import STDesign
@testable import STPlatform
import SwiftUI
import Testing
@testable import KeyRebinder

/// The key panel's editor with Karabiner profiles (spec 6.1): the profile row under the Does chips, saved after the tools'
/// actions, and a row that says when its profile can't be switched to. Karabiner-Elements here lists one profile, "P".
@MainActor
@Suite("Key panel profiles", .serialized)
struct KeyPanelProfileTests {
    @Test func aDraftKeepsTheProfileApartFromTheChips() {
        let binding = HotkeyBinding(combo: HotkeyCombo(keyCode: 79, modifiers: .option),
                                    actions: [.toggle(.crosshair), .profile(.select("Minecraft"))])
        let draft = HotkeyDraft(binding)
        #expect(draft.does == [.toggle(.crosshair)])
        #expect(draft.profile == .select("Minecraft"))
        #expect(draft.actions == [.toggle(.crosshair), .profile(.select("Minecraft"))])
        #expect(HotkeyDraft().profile == nil)
    }

    /// A profile alone is enough to save, as an action is.
    @Test func aProfileAloneCanBeSaved() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        var draft = HotkeyDraft()
        #expect(!draft.canSave(on: 79, in: rig.center))
        draft.profile = .next
        #expect(draft.canSave(on: 79, in: rig.center))
        #expect(draft.actions == [.profile(.next)])
        let id = try #require(rig.controller.saveHotkey(on: .key("caps_lock"), editing: nil, modifiers: draft.modifiers,
                                                        actions: draft.actions))
        #expect(rig.center.bindings.first { $0.id == id }?.actions == [.profile(.next)])
    }

    @Test func aRowSaysWhenItsProfileIsGone() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        let gone = await rig.add("f18", [], [.profile(.select("Minecraft"))])
        let fine = await rig.add("f18", .option, [.toggle(.crosshair), .profile(.select("P"))])
        let binding = { (id: UUID) in try #require(rig.center.bindings.first { $0.id == id }) }
        #expect(KeyHotkeysBlock.problem(of: try binding(gone), controller: rig.controller) == "No profile named \u{201C}Minecraft\u{201D}")
        #expect(KeyHotkeysBlock.problem(of: try binding(fine), controller: rig.controller) == nil)
        #expect(KeyHotkeysBlock.spokenDescription(name: "F18", actions: try binding(gone).actions,
                                                  problem: KeyHotkeysBlock.problem(of: try binding(gone), controller: rig.controller))
            == "F18: Switch to Minecraft. No profile named \u{201C}Minecraft\u{201D}.")
    }

    /// The editor draws the profile row, and a choice changes what it draws.
    @Test func theEditorDrawsTheProfileRow() async throws {
        let rig = try HotkeyViewRig(config: HotkeyViewRig.profile([("caps_lock", "f18")]))
        defer { rig.remove() }
        await rig.prepare()
        STFont.register()
        var draft = HotkeyDraft()
        draft.does = [.toggle(.crosshair)]
        func block(_ draft: HotkeyDraft) -> Data? {
            let size = CGSize(width: 600, height: 520)
            let host = NSHostingView(rootView: KeyHotkeysBlock(controller: rig.controller, key: .key("caps_lock"), chosen: .constant(nil),
                                                               openHotkeys: nil, draft: draft)
                .padding(16)
                .environment(\.stTheme, STTheme())
                .environment(\.stSoundPlayer, STSoundPlayer.silent)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(STColor.background))
            host.frame = CGRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        let none = block(draft)
        draft.profile = .select("P")
        let chosen = block(draft)
        #expect(none != nil && chosen != nil)
        #expect(none != chosen)
    }
}
