import Foundation
import Testing
@testable import KeyRebinder

private func text(named name: String) -> String {
    let url = FixtureLoader.directory.appending(path: name)
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
        fatalError("missing fixture \(name)")
    }
    return text
}

@Suite struct MinecraftKeyNameTests {
    /// Every keyboard name Minecraft 1.16.1 can write after `key.keyboard.`.
    static let allKeyboardNames: [String] = {
        var names = ["unknown", "space", "apostrophe", "comma", "minus", "period", "slash", "semicolon", "equal",
                     "left.bracket", "backslash", "right.bracket", "grave.accent", "world.1", "world.2", "escape",
                     "enter", "tab", "backspace", "insert", "delete", "right", "left", "down", "up", "page.up",
                     "page.down", "home", "end", "caps.lock", "scroll.lock", "num.lock", "print.screen", "pause",
                     "keypad.decimal", "keypad.divide", "keypad.multiply", "keypad.subtract", "keypad.add",
                     "keypad.enter", "keypad.equal", "left.shift", "left.control", "left.alt", "left.win",
                     "right.shift", "right.control", "right.alt", "right.win", "menu"]
        names += (0...9).map(String.init)
        names += (0...9).map { "keypad.\($0)" }
        names += "abcdefghijklmnopqrstuvwxyz".map(String.init)
        names += (1...25).map { "f\($0)" }
        return names
    }()

    static let unmappable: Set<String> = ["unknown", "world.1", "world.2", "f25"]

    @Test func everyKeyboardNameIsMappedOrDocumentedAsUnmappable() {
        for name in Self.allKeyboardNames {
            let event = MinecraftKeyNames.event(forName: "key.keyboard.\(name)")
            if Self.unmappable.contains(name) {
                #expect(event == nil, "\(name)")
            } else {
                #expect(event != nil, "\(name) has no Karabiner key code")
            }
        }
    }

    @Test func mappedCodesAreRealKarabinerKeyCodes() {
        let valid = Set(text(named: "rules-karabiner-codes.txt").split(separator: "\n").map(String.init))
        for name in Self.allKeyboardNames {
            guard case .key(let code)? = MinecraftKeyNames.event(forName: "key.keyboard.\(name)") else { continue }
            #expect(valid.contains("key \(code)"), "\(name) -> \(code)")
        }
        for name in ["left", "right", "middle", "4", "5", "6", "7", "8"] {
            guard case .pointing(let code)? = MinecraftKeyNames.event(forName: "key.mouse.\(name)") else {
                Issue.record("mouse \(name)")
                continue
            }
            #expect(valid.contains("pointing \(code)"))
        }
    }

    @Test func spotChecksOfTheMacTranslation() {
        let expectations: [(String, KarabinerEvent)] = [
            ("key.keyboard.left.shift", .key("left_shift")),
            ("key.keyboard.right.alt", .key("right_option")),
            ("key.keyboard.left.win", .key("left_command")),
            ("key.keyboard.grave.accent", .key("grave_accent_and_tilde")),
            ("key.keyboard.apostrophe", .key("quote")),
            ("key.keyboard.minus", .key("hyphen")),
            ("key.keyboard.equal", .key("equal_sign")),
            ("key.keyboard.left.bracket", .key("open_bracket")),
            ("key.keyboard.right.bracket", .key("close_bracket")),
            ("key.keyboard.space", .key("spacebar")),
            ("key.keyboard.enter", .key("return_or_enter")),
            ("key.keyboard.backspace", .key("delete_or_backspace")),
            ("key.keyboard.delete", .key("delete_forward")),
            ("key.keyboard.up", .key("up_arrow")),
            ("key.keyboard.page.down", .key("page_down")),
            ("key.keyboard.keypad.add", .key("keypad_plus")),
            ("key.keyboard.keypad.subtract", .key("keypad_hyphen")),
            ("key.keyboard.keypad.7", .key("keypad_7")),
            ("key.keyboard.num.lock", .key("keypad_num_lock")),
            ("key.keyboard.menu", .key("application")),
            ("key.keyboard.f24", .key("f24")),
            ("key.keyboard.7", .key("7")),
            ("key.mouse.left", .pointing("button1")),
            ("key.mouse.right", .pointing("button2")),
            ("key.mouse.middle", .pointing("button3")),
            ("key.mouse.4", .pointing("button4")),
            ("key.mouse.8", .pointing("button8")),
        ]
        for (name, expected) in expectations {
            #expect(MinecraftKeyNames.event(forName: name) == expected, "\(name)")
        }
    }

    @Test func rejectsUnknownNames() {
        #expect(MinecraftKeyNames.event(forName: "key.keyboard.nonsense") == nil)
        #expect(MinecraftKeyNames.event(forName: "key.mouse.0") == nil)
        #expect(MinecraftKeyNames.event(forName: "key.mouse.left.extra") == nil)
        #expect(MinecraftKeyNames.event(forName: "w") == nil)
        #expect(MinecraftKeyNames.event(forName: "") == nil)
    }

    @Test func legacyNumericCodes() {
        let expectations: [(Int, KarabinerEvent?)] = [
            (-100, .pointing("button1")), (-99, .pointing("button2")), (-98, .pointing("button3")),
            (-97, .pointing("button4")), (-93, .pointing("button8")),
            (0, nil), (1, .key("escape")), (2, .key("1")), (11, .key("0")), (12, .key("hyphen")),
            (14, .key("delete_or_backspace")), (16, .key("q")), (17, .key("w")), (18, .key("e")), (30, .key("a")),
            (41, .key("grave_accent_and_tilde")), (42, .key("left_shift")), (57, .key("spacebar")),
            (59, .key("f1")), (68, .key("f10")), (87, .key("f11")), (88, .key("f12")), (100, .key("f13")),
            (156, .key("keypad_enter")), (157, .key("right_control")), (184, .key("right_option")),
            (200, .key("up_arrow")), (203, .key("left_arrow")), (205, .key("right_arrow")), (208, .key("down_arrow")),
            (219, .key("left_command")), (999, nil), (-50, nil),
        ]
        for (code, expected) in expectations {
            #expect(MinecraftKeyNames.event(forLegacyCode: code) == expected, "\(code)")
        }
    }

    @Test func legacyKeyboardCodesAreRealKarabinerKeyCodes() {
        let valid = Set(text(named: "rules-karabiner-codes.txt").split(separator: "\n").map(String.init))
        for code in 1...300 {
            guard let event = MinecraftKeyNames.event(forLegacyCode: code), case .key(let name) = event else { continue }
            #expect(valid.contains("key \(name)"), "\(code) -> \(name)")
        }
    }
}

@Suite struct MinecraftOptionsParserTests {
    private func keybinds(_ options: String) -> [MinecraftKeybind] { MinecraftKeybinds.parse(optionsText: options) }
    private func bind(_ action: MinecraftAction, in list: [MinecraftKeybind]) -> MinecraftKeybind? {
        list.first { $0.action == action }
    }

    @Test func parsesTheFullOptionsFile() {
        let list = keybinds(text(named: "rules-options-1.16.1.txt"))
        #expect(bind(.attack, in: list)?.event == .pointing("button1"))
        #expect(bind(.attack, in: list)?.display == "Attack/Destroy")
        #expect(bind(.use, in: list)?.event == .pointing("button2"))
        #expect(bind(.use, in: list)?.display == "Use Item/Place Block")
        #expect(bind(.forward, in: list)?.event == .key("w"))
        #expect(bind(.sneak, in: list)?.event == .key("left_shift"))
        #expect(bind(.sprint, in: list)?.event == .key("left_control"))
        #expect(bind(.jump, in: list)?.event == .key("spacebar"))
        #expect(bind(.dropItem, in: list)?.display == "Drop item")
        #expect(bind(.inventory, in: list)?.event == .key("e"))
        #expect(bind(.chat, in: list)?.event == .key("t"))
        #expect(bind(.playerList, in: list)?.event == .key("tab"))
        #expect(bind(.pickBlock, in: list)?.event == .pointing("button3"))
        #expect(bind(.command, in: list)?.event == .key("slash"))
        #expect(bind(.perspective, in: list)?.event == .key("f5"))
        #expect(bind(.swapHands, in: list)?.event == .key("grave_accent_and_tilde"))
        #expect(bind(.swapHands, in: list)?.display == "Swap hands")
        #expect(bind(.advancements, in: list)?.event == .key("l"))
        #expect(bind(.fullscreen, in: list)?.event == .key("f11"))
    }

    @Test func hotbarSlotsOneThroughNine() {
        let list = keybinds(text(named: "rules-options-1.16.1.txt"))
        for slot in 1...9 {
            #expect(bind(.hotbar(slot), in: list)?.event == .key(String(slot)))
            #expect(bind(.hotbar(slot), in: list)?.display == "Hotbar \(slot)")
        }
    }

    @Test func unboundKeysKeepTheirActionWithNoEvent() {
        let list = keybinds(text(named: "rules-options-1.16.1.txt"))
        let camera = bind(.cinematicCamera, in: list)
        #expect(camera != nil)
        #expect(camera?.event == nil)
        #expect(camera?.minecraftKey == "key.keyboard.unknown")
    }

    @Test func keepsTheFileOrderAndIgnoresNonKeyLines() {
        let list = keybinds("fov:1.0\nkey_key.jump:key.keyboard.space\nlang:en_us\nkey_key.attack:key.mouse.left\n")
        let optionActions = list.prefix(2).map(\.action)
        #expect(optionActions == [.jump, .attack])
    }

    @Test func toleratesWindowsLineEndingsAndSpaces() {
        let list = keybinds("key_key.jump:key.keyboard.space\r\n  key_key.sneak:key.keyboard.left.shift  \r\n")
        #expect(bind(.jump, in: list)?.event == .key("spacebar"))
        #expect(bind(.sneak, in: list)?.event == .key("left_shift"))
    }

    @Test func unknownActionsAreKeptAsCustom() {
        let list = keybinds("key_key.mymod.openMap:key.keyboard.m\n")
        let entry = list.first
        #expect(entry?.action == .custom("key.mymod.openMap"))
        #expect(entry?.display == "key.mymod.openMap")
        #expect(entry?.event == .key("m"))
    }

    @Test func unknownKeyNamesGiveNoEventButKeepTheRawName() {
        let list = keybinds("key_key.jump:key.keyboard.world.1\nkey_key.sneak:garbage\nkey_key.chat:\nkey_key.drop\n")
        #expect(bind(.jump, in: list)?.event == nil)
        #expect(bind(.jump, in: list)?.minecraftKey == "key.keyboard.world.1")
        #expect(bind(.sneak, in: list)?.event == nil)
        #expect(bind(.chat, in: list)?.event == nil)
        #expect(bind(.dropItem, in: list) == nil)
    }

    @Test func modifierSuffixesOnlyCountWhenNone() {
        let list = keybinds("key_key.jump:key.keyboard.space:NONE\nkey_key.sneak:key.keyboard.left.shift:CONTROL\n")
        #expect(bind(.jump, in: list)?.event == .key("spacebar"))
        #expect(bind(.sneak, in: list)?.event == nil)
        #expect(bind(.sneak, in: list)?.minecraftKey == "key.keyboard.left.shift")
    }

    @Test func parsesTheOlderNumericForms() {
        let list = keybinds(text(named: "rules-options-1.12.2.txt"))
        #expect(bind(.attack, in: list)?.event == .pointing("button1"))
        #expect(bind(.use, in: list)?.event == .pointing("button2"))
        #expect(bind(.pickBlock, in: list)?.event == .pointing("button3"))
        #expect(bind(.forward, in: list)?.event == .key("w"))
        #expect(bind(.strafeLeft, in: list)?.event == .key("a"))
        #expect(bind(.sneak, in: list)?.event == .key("left_shift"))
        #expect(bind(.jump, in: list)?.event == .key("spacebar"))
        #expect(bind(.dropItem, in: list)?.event == .key("q"))
        #expect(bind(.inventory, in: list)?.event == .key("e"))
        #expect(bind(.swapHands, in: list)?.event == .key("f"))
        #expect(bind(.perspective, in: list)?.event == .key("f5"))
        #expect(bind(.screenshot, in: list)?.event == .key("f2"))
        #expect(bind(.cinematicCamera, in: list)?.event == nil)
        #expect(bind(.hotbar(1), in: list)?.event == .key("1"))
        #expect(bind(.hotbar(9), in: list)?.event == .key("9"))
        #expect(bind(.attack, in: list)?.minecraftKey == "-100")
    }

    @Test func swapHandsHasBothSpellings() {
        #expect(bind(.swapHands, in: keybinds("key_key.swapOffhand:key.keyboard.f\n"))?.event == .key("f"))
        #expect(bind(.swapHands, in: keybinds("key_key.swapHands:33\n"))?.event == .key("f"))
    }

    @Test func emptyAndGarbageInputGiveOnlyFixedKeys() {
        let fixedCount = MinecraftKeybinds.fixedKeybinds.count + 1
        #expect(keybinds("").count == fixedCount)
        #expect(keybinds("\u{0}\u{1}nonsense\n:::\nkey_").count == fixedCount)
    }
}

@Suite struct MinecraftFixedKeyTests {
    @Test func debugScreenIsF3AndNotAnOptionsKey() {
        let debug = MinecraftKeybinds.fixedKeybinds.first { $0.action == .debugScreen }
        #expect(debug?.display == "Debug screen")
        #expect(debug?.event == .key("f3"))
        #expect(MinecraftKeybinds.fixedKeybinds.contains { $0.action == .hideHUD && $0.event == .key("f1") })
        #expect(MinecraftKeybinds.fixedKeybinds.contains { $0.action == .pauseMenu && $0.event == .key("escape") })
    }

    @Test func parseAppendsTheFixedKeysAfterTheFileEntries() {
        let list = MinecraftKeybinds.parse(optionsText: "key_key.jump:key.keyboard.space\n")
        #expect(list.first?.action == .jump)
        #expect(list.contains { $0.action == .debugScreen })
        #expect(list.contains { $0.action == .hideHUD })
    }

    @Test func fullscreenIsFixedToF11OnlyWhenTheFileHasNoSuchKey() {
        let without = MinecraftKeybinds.parse(optionsText: "key_key.jump:key.keyboard.space\n")
        #expect(without.contains { $0.action == .fullscreen && $0.event == .key("f11") })
        let rebound = MinecraftKeybinds.parse(optionsText: "key_key.fullscreen:key.keyboard.f9\n")
        #expect(rebound.filter { $0.action == .fullscreen }.map(\.event) == [.key("f9")])
    }
}

@Suite struct MinecraftOptionsLocationTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "krrules-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func findsOptionsTxtDirectlyInTheGameDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "x".write(to: directory.appending(path: "options.txt"), atomically: true, encoding: .utf8)
        #expect(MinecraftKeybinds.locateOptionsFile(gameDirectory: directory)?.lastPathComponent == "options.txt")
        #expect(MinecraftKeybinds.locateOptionsFile(gameDirectory: directory)?.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    }

    @Test func looksInsideInstanceFolders() throws {
        for sub in [".minecraft", "minecraft"] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let inner = directory.appending(path: sub, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try "x".write(to: inner.appending(path: "options.txt"), atomically: true, encoding: .utf8)
            #expect(MinecraftKeybinds.locateOptionsFile(gameDirectory: directory)?.path.hasSuffix("\(sub)/options.txt") == true)
        }
    }

    @Test func prefersTheDirectFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inner = directory.appending(path: ".minecraft", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try "x".write(to: inner.appending(path: "options.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: directory.appending(path: "options.txt"), atomically: true, encoding: .utf8)
        #expect(MinecraftKeybinds.locateOptionsFile(gameDirectory: directory)?.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent)
    }

    @Test func returnsNilWhenThereIsNoFileOrTheDirectoryIsMissing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(MinecraftKeybinds.locateOptionsFile(gameDirectory: directory) == nil)
        #expect(MinecraftKeybinds.locateOptionsFile(gameDirectory: directory.appending(path: "missing")) == nil)
    }

    @Test func aDirectoryNamedOptionsTxtIsNotAFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appending(path: "options.txt"), withIntermediateDirectories: true)
        #expect(MinecraftKeybinds.locateOptionsFile(gameDirectory: directory) == nil)
    }

    @Test func fileExistenceIsInjectable() {
        let base = URL(fileURLWithPath: "/virtual/game", isDirectory: true)
        let wanted = base.appending(path: ".minecraft").appending(path: "options.txt").path
        let found = MinecraftKeybinds.locateOptionsFile(gameDirectory: base, fileExists: { $0.path == wanted })
        #expect(found?.path == wanted)
    }
}
