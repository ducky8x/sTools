import Foundation
import Testing
@testable import KeyRebinder

@Suite struct KeyTableTests {
    let table = KeyTable.shared

    @Test func holdsEveryPickerEntryAndCategory() {
        #expect(table.entries.count == 667)
        #expect(table.categories.count == 22)
        #expect(table.categories.first?.id == "disable")
        #expect(table.categories.first(where: { $0.id == "letters" })?.title == "Letter keys")
    }

    @Test func containsEveryEditableKind() {
        #expect(table.entry(for: .key("caps_lock"))?.category == "modifiers")
        #expect(table.entry(for: .consumer("mute"))?.category == "media")
        #expect(table.entry(for: .pointing("button4"))?.category == "mouse_buttons")
        #expect(table.entries.filter { if case .pointing = $0.event { true } else { false } }.count == 255)
        #expect(table.entry(for: .other(.object([JSONMember("apple_vendor_keyboard_key_code", "spotlight")])))?.label == "spotlight")
        #expect(table.entry(for: .other(.object([JSONMember("generic_desktop", "do_not_disturb")])))?.category == "media")
    }

    @Test func labelsAreEnglishAndFallBackToTheCode() {
        #expect(table.label(for: .key("left_control")) == "left_control")
        #expect(table.label(for: .key("hyphen")) == "hyphen (-)")
        #expect(table.label(for: .consumer("al_terminal_lock_or_screensaver")) == "Lock key on Magic Keyboard without Touch ID")
        #expect(table.label(for: .key("not_a_real_key")) == "not_a_real_key")
        #expect(table.label(for: .other(["shell_command": "x"])).contains("shell_command"))
    }

    @Test func sourceAndTargetFlagsFollowKarabiner() {
        #expect(table.entry(for: .key("vk_none"))?.canBeSource == false)
        #expect(table.entry(for: .key("f21"))?.canBeTarget == false)
        #expect(table.entry(for: .key("a"))?.canBeSource == true)
        #expect(table.entry(for: .pointing("button1"))?.isUnsafeSource == true)
        #expect(table.entry(for: .pointing("button2"))?.isUnsafeSource == false)
    }

    @Test func compoundEntriesKeepEveryEvent() {
        let sticky = table.entries.first { $0.label == "sticky left_control" }
        #expect(sticky?.event == .other(.array([["sticky_modifier": ["left_control": "toggle"]], ["key_code": "left_control"]])))
    }

    @Test func eventsForCategoryKeepPickerOrder() {
        let arrows = table.events(forCategory: "arrows")
        #expect(arrows.first == .key("up_arrow"))
        #expect(arrows.count == 8)
        #expect(table.events(forCategory: "no_such_category").isEmpty)
    }

    @Test func modifiersAreRecognized() {
        for code in ["caps_lock", "fn", "left_shift", "right_command", "left_alt", "right_gui"] {
            #expect(table.isModifier(.key(code)))
        }
        #expect(!table.isModifier(.key("a")))
        #expect(!table.isModifier(.consumer("mute")))
    }

    @Test func virtualKeyCodesMatchKnownPairs() {
        let pairs: [(Int, String)] = [
            (0x00, "a"), (0x0B, "b"), (0x35, "escape"), (0x24, "return_or_enter"), (0x33, "delete_or_backspace"),
            (0x31, "spacebar"), (0x30, "tab"), (0x39, "caps_lock"), (0x38, "left_shift"), (0x3C, "right_shift"),
            (0x3B, "left_control"), (0x3E, "right_control"), (0x3A, "left_option"), (0x3D, "right_option"),
            (0x37, "left_command"), (0x36, "right_command"), (0x3F, "fn"), (0x7A, "f1"), (0x63, "f3"), (0x6F, "f12"),
            (0x69, "f13"), (0x7B, "left_arrow"), (0x7E, "up_arrow"), (0x32, "grave_accent_and_tilde"),
            (0x2A, "backslash"), (0x72, "insert"), (0x47, "keypad_num_lock"), (0x52, "keypad_0"), (0x0A, "non_us_backslash"),
            (0x66, "lang2"), (0x68, "lang1"),
        ]
        for (virtualKey, code) in pairs {
            #expect(table.entry(forVirtualKeyCode: virtualKey)?.event == .key(code), Comment(rawValue: "kVK \(virtualKey)"))
            #expect(table.virtualKeyCode(for: .key(code)) == virtualKey, Comment(rawValue: code))
        }
    }

    @Test func sharedVirtualKeyCodesListEveryName() {
        #expect(table.keyCodes(forVirtualKeyCode: 0x69) == ["f13", "print_screen"])
        #expect(table.keyCodes(forVirtualKeyCode: 0x3A) == ["left_option", "left_alt"])
        #expect(table.virtualKeyCode(for: .key("print_screen")) == 0x69)
        #expect(table.keyCodes(forVirtualKeyCode: 0xFFF).isEmpty)
        #expect(table.entry(forVirtualKeyCode: 0xFFF) == nil)
        #expect(table.virtualKeyCode(for: .consumer("mute")) == nil)
    }

    @Test func everyMappedKeyCodeExistsInTheTable() {
        for virtualKey in 0..<0x200 {
            for code in table.keyCodes(forVirtualKeyCode: virtualKey) {
                #expect(table.entry(for: .key(code)) != nil, Comment(rawValue: code))
            }
        }
    }

    @Test func rejectsATableInAnUnexpectedFormat() {
        #expect(throws: KeyTableError.unexpectedFormat) { try KeyTable(data: Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try KeyTable(data: Data("nope".utf8)) }
    }

    @Test func readsAMinimalTable() throws {
        let json = """
        {"format":1,"categories":[{"id":"c","title":"C"}],
         "keys":[{"category":"c","events":[{"key_code":"a"}],"label":"A","noTo":true}],
         "virtualKeys":[{"keyCodes":["a"],"vk":0}]}
        """
        let small = try KeyTable(data: Data(json.utf8))
        #expect(small.entries.count == 1)
        #expect(small.entry(for: .key("a"))?.canBeTarget == false)
        #expect(small.entry(forVirtualKeyCode: 0)?.label == "A")
    }
}

@Suite struct KeyTableResourceTests {
    @Test func findsTheTableInAPackagedAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "keytable-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appending(path: "\(KeyTableResources.bundleName)/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: resources.appending(path: "KeyTable.json"))
        let found = KeyTableResources.locate(mainResourceURL: root)
        #expect(found?.lastPathComponent == "KeyTable.json")
        #expect(found?.path.contains(KeyTableResources.bundleName) == true)
    }

    @Test func fallsBackToTheModuleBundle() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "no-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(KeyTableResources.locate(mainResourceURL: empty) == nil)
        #expect(KeyTableResources.locate(mainResourceURL: nil) == nil)
        #expect(KeyTableResources.tableURL(mainResourceURL: empty) != nil)
    }
}

@Suite struct KarabinerEventJSONTests {
    @Test func readsTypedEvents() {
        #expect(KarabinerEvent(json: ["key_code": "a"]) == .key("a"))
        #expect(KarabinerEvent(json: ["consumer_key_code": "mute"]) == .consumer("mute"))
        #expect(KarabinerEvent(json: ["pointing_button": "button1"]) == .pointing("button1"))
    }

    @Test func keepsAnythingElseVerbatim() {
        let withModifiers: JSONValue = ["key_code": "a", "modifiers": ["left_shift"]]
        #expect(KarabinerEvent(json: withModifiers) == .other(withModifiers))
        let vendor: JSONValue = ["apple_vendor_keyboard_key_code": "spotlight"]
        #expect(KarabinerEvent(json: vendor) == .other(vendor))
        #expect(KarabinerEvent(json: ["key_code": 5]) == .other(["key_code": 5]))
    }

    @Test func roundTripsThroughJSON() {
        for event in [KarabinerEvent.key("a"), .consumer("mute"), .pointing("button3"), .other(["mouse_key": ["x": 1536]])] {
            #expect(KarabinerEvent(json: event.json) == event)
            #expect(event.toValue == .array([event.json]))
        }
    }

    @Test func toValueHandlesListsAndOldObjects() {
        #expect(KarabinerEvent(toValue: [["key_code": "a"]]) == .key("a"))
        #expect(KarabinerEvent(toValue: ["key_code": "a"]) == .key("a"))
        let two: JSONValue = [["key_code": "a"], ["key_code": "b"]]
        let compound = KarabinerEvent(toValue: two)
        #expect(compound == .other(two))
        #expect(compound.toValue == two)
        #expect(KarabinerEvent(toValue: []) == .other([]))
    }

    @Test func plainEventsAreLoneKnownMembers() {
        #expect(KarabinerEvent.key("a").isPlainEvent)
        #expect(KarabinerEvent.other(["apple_vendor_top_case_key_code": "keyboard_fn"]).isPlainEvent)
        #expect(!KarabinerEvent.other(["key_code": "a", "lazy": true]).isPlainEvent)
        #expect(!KarabinerEvent.other(["shell_command": "open -a Safari"]).isPlainEvent)
        #expect(!KarabinerEvent.other([["key_code": "a"], ["key_code": "b"]]).isPlainEvent)
    }
}
