import Testing
@testable import KeyRebinder

@Suite struct TreeDiffTests {
    @Test func reportsOnlyDifferingPaths() {
        let before = TestConfig.parse(#"{ "a": { "b": 1, "c": [1, 2] }, "d": "x" }"#)
        let after = TestConfig.parse(#"{ "a": { "b": 1, "c": [1, 3] }, "d": "x", "e": true }"#)
        #expect(changedPaths(before, after) == ["a.c[1]", "e"])
        #expect(changedPaths(before, before).isEmpty)
        #expect(changedPaths(.array([1]), .array([1, 2]), path: "list") == ["list"])
    }
}

@Suite struct RebindReadingTests {
    @Test func readsTheTypicalProfileInEveryScope() {
        let config = TestConfig.fixture("typical")
        let all = RebindEditor.rebinds(in: config, profile: "Default profile")
        #expect(all == [
            Rebind(from: .key("caps_lock"), to: .key("escape"), scope: .allDevices),
            Rebind(from: .key("f13"), to: .pointing("button5"), scope: .allDevices),
        ])
        let keyboard = RebindEditor.rebinds(in: config, profile: "Default profile", scope: .device(TestConfig.keyboard))
        #expect(keyboard.map(\.from) == [.key("left_option")])
        #expect(keyboard.map(\.to) == [.key("left_command")])
        let mouse = RebindEditor.rebinds(in: config, profile: "Default profile", scope: .device(TestConfig.mouse))
        #expect(mouse.map(\.from) == [.pointing("button4")])
    }

    @Test func missingPiecesReadAsEmpty() {
        let minimal = TestConfig.fixture("minimal")
        #expect(RebindEditor.rebinds(in: minimal, profile: "Default profile").isEmpty)
        #expect(RebindEditor.rebinds(in: minimal, profile: "Default profile", scope: .device(TestConfig.keyboard)).isEmpty)
        #expect(RebindEditor.rebinds(in: minimal, profile: "Nope").isEmpty)
        let future = TestConfig.fixture("future-keys")
        #expect(RebindEditor.rebinds(in: future, profile: "Stage ✦ 日本語").map(\.from) == [.key("caps_lock")])
        #expect(RebindEditor.rebinds(in: future, profile: "Stage ✦ 日本語", scope: .device(DeviceIdentifiers(vendorID: 1452, productID: 834, isKeyboard: true))).isEmpty)
    }

    @Test func lastDuplicateWinsAsInKarabiner() {
        let config = TestConfig.profile(simple: "[\(TestConfig.pair("a", "b")), \(TestConfig.pair("c", "d")), \(TestConfig.pair("a", "e"))]")
        let effective = RebindEditor.rebinds(in: config, profile: "P")
        #expect(effective.map(\.from) == [.key("c"), .key("a")])
        #expect(effective.last?.to == .key("e"))
        let all = RebindEditor.rebinds(in: config, profile: "P", includeOverridden: true)
        #expect(all.map(\.isOverridden) == [true, false, false])
        #expect(all.first?.to == .key("b"))
    }

    @Test func multiEventAndOldStyleTargetsStayVisible() {
        let config = TestConfig.profile(simple: """
        [
            { "from": { "key_code": "a" }, "to": [{ "key_code": "b" }, { "key_code": "c" }] },
            { "from": { "key_code": "d" }, "to": { "key_code": "e" } },
            { "from": { "key_code": "f" }, "to": [{ "key_code": "g", "modifiers": ["left_shift"] }] },
            { "from": {}, "to": [{ "key_code": "z" }] },
            "junk"
        ]
        """)
        let rebinds = RebindEditor.rebinds(in: config, profile: "P")
        #expect(rebinds.count == 3)
        #expect(rebinds[0].to == .other([["key_code": "b"], ["key_code": "c"]]))
        #expect(rebinds[1].to == .key("e"))
        #expect(rebinds[2].to == .other(["key_code": "g", "modifiers": ["left_shift"]]))
    }
}

@Suite struct RebindSetTests {
    static let names = FixtureLoader.names

    @Test(arguments: names)
    func addsAnAllDevicesRebindChangingOnlyThatList(fixture: String) throws {
        let config = TestConfig.fixture(fixture)
        let profile = try #require(RebindEditor.profileNames(in: config).first)
        let updated = try RebindEditor.setRebind(in: config, profile: profile, from: .key("q"), to: .key("r"))
        #expect(RebindEditor.rebinds(in: updated, profile: profile).last == Rebind(from: .key("q"), to: .key("r"), scope: .allDevices))
        #expect(changedPaths(config, updated) == ["profiles[0].simple_modifications"])
    }

    @Test func createsTheMissingListAndWritesKarabinersEntryShape() throws {
        let updated = try RebindEditor.setRebind(
            in: TestConfig.fixture("minimal"), profile: "Default profile", from: .key("caps_lock"), to: .key("escape"))
        let list = try #require(updated["profiles"]?[index: 0]?["simple_modifications"])
        #expect(list == [["from": ["key_code": "caps_lock"], "to": [["key_code": "escape"]]]])
    }

    @Test func replacesTheEntryWithTheSameFromKeepingItsPositionAndExtraKeys() throws {
        let config = TestConfig.fixture("future-keys")
        let updated = try RebindEditor.setRebind(in: config, profile: "Stage ✦ 日本語", from: .key("caps_lock"), to: .key("tab"))
        #expect(changedPaths(config, updated) == ["profiles[0].simple_modifications[0].to[0].key_code"])
        let entry = try #require(updated["profiles"]?[index: 0]?["simple_modifications"]?[index: 0])
        #expect(entry.members?.map(\.key) == ["to", "from", "x_annotation"])
        #expect(entry["x_annotation"] == "kept")
    }

    @Test func replacesAnEntryWhoseTargetIsAnotherKind() throws {
        let config = TestConfig.fixture("typical")
        let updated = try RebindEditor.setRebind(in: config, profile: "Default profile", from: .key("f13"), to: .consumer("mute"))
        let rebinds = RebindEditor.rebinds(in: updated, profile: "Default profile")
        #expect(rebinds.map(\.to) == [.key("escape"), .consumer("mute")])
        #expect(changedPaths(config, updated) == [
            "profiles[0].simple_modifications[1].to[0].pointing_button",
            "profiles[0].simple_modifications[1].to[0].consumer_key_code",
        ])
    }

    @Test func writesAMultiEventTargetAsTheListItself() throws {
        let compound = KarabinerEvent.other([["sticky_modifier": ["left_shift": "toggle"]], ["key_code": "left_shift"]])
        let updated = try RebindEditor.setRebind(in: TestConfig.fixture("minimal"), profile: "Default profile", from: .key("a"), to: compound)
        #expect(RebindEditor.rebinds(in: updated, profile: "Default profile").first?.to == compound)
    }

    @Test func rebindingAKeyToItselfRemovesTheEntry() throws {
        let config = TestConfig.fixture("typical")
        let updated = try RebindEditor.setRebind(in: config, profile: "Default profile", from: .key("caps_lock"), to: .key("caps_lock"))
        #expect(RebindEditor.rebinds(in: updated, profile: "Default profile").map(\.from) == [.key("f13")])
        #expect(changedPaths(config, updated) == ["profiles[0].simple_modifications"])
    }

    @Test func replacingADuplicateUpdatesTheWinnerAndDropsTheDeadEntries() throws {
        let config = TestConfig.profile(simple: "[\(TestConfig.pair("a", "b")), \(TestConfig.pair("c", "d")), \(TestConfig.pair("a", "e"))]")
        let updated = try RebindEditor.setRebind(in: config, profile: "P", from: .key("a"), to: .key("f"))
        let all = RebindEditor.rebinds(in: updated, profile: "P", includeOverridden: true)
        #expect(all.map(\.from) == [.key("c"), .key("a")])
        #expect(all.map(\.to) == [.key("d"), .key("f")])
    }

    @Test func throwsForAnUnknownProfileAndMalformedLists() {
        let config = TestConfig.fixture("minimal")
        #expect(throws: EditError.profileNotFound("Nope")) {
            try RebindEditor.setRebind(in: config, profile: "Nope", from: .key("a"), to: .key("b"))
        }
        #expect(throws: EditError.profileNotFound("Nope")) {
            try RebindEditor.removeRebind(in: config, profile: "Nope", from: .key("a"))
        }
        let broken = TestConfig.profile(simple: "{}")
        #expect(throws: EditError.malformedConfig("profile simple_modifications is not an array")) {
            try RebindEditor.setRebind(in: broken, profile: "P", from: .key("a"), to: .key("b"))
        }
        let brokenDevices = TestConfig.profile(devices: "5")
        #expect(throws: EditError.malformedConfig("profile devices is not an array")) {
            try RebindEditor.setRebind(in: brokenDevices, profile: "P", from: .key("a"), to: .key("b"), scope: .device(TestConfig.keyboard))
        }
    }

    @Test func leavesAProfileWithTheSameNameLaterAlone() throws {
        let config = TestConfig.parse(#"{ "profiles": [{ "name": "X" }, { "name": "X" }] }"#)
        let updated = try RebindEditor.setRebind(in: config, profile: "X", from: .key("a"), to: .key("b"))
        #expect(changedPaths(config, updated) == ["profiles[0].simple_modifications"])
    }
}

@Suite struct RebindRemoveTests {
    @Test(arguments: FixtureLoader.names)
    func removingAnAbsentRebindChangesNothing(fixture: String) throws {
        let config = TestConfig.fixture(fixture)
        let profile = try #require(RebindEditor.profileNames(in: config).first)
        #expect(try RebindEditor.removeRebind(in: config, profile: profile, from: .key("q")) == config)
        #expect(try RebindEditor.removeRebind(in: config, profile: profile, from: .key("q"), scope: .device(TestConfig.mouse)) == config)
    }

    @Test func removesTheEntryAndLeavesAnEmptyListBehind() throws {
        let config = TestConfig.fixture("future-keys")
        let updated = try RebindEditor.removeRebind(in: config, profile: "Stage ✦ 日本語", from: .key("caps_lock"))
        #expect(updated["profiles"]?[index: 0]?["simple_modifications"] == [])
        #expect(changedPaths(config, updated) == ["profiles[0].simple_modifications"])
    }

    @Test func removesEveryDuplicate() throws {
        let config = TestConfig.profile(simple: "[\(TestConfig.pair("a", "b")), \(TestConfig.pair("c", "d")), \(TestConfig.pair("a", "e"))]")
        let updated = try RebindEditor.removeRebind(in: config, profile: "P", from: .key("a"))
        #expect(RebindEditor.rebinds(in: updated, profile: "P", includeOverridden: true).map(\.from) == [.key("c")])
    }

    @Test func removesFromADeviceOnly() throws {
        let config = TestConfig.fixture("typical")
        let updated = try RebindEditor.removeRebind(in: config, profile: "Default profile", from: .key("left_option"), scope: .device(TestConfig.keyboard))
        #expect(changedPaths(config, updated) == ["profiles[0].devices[0].simple_modifications"])
        #expect(RebindEditor.rebinds(in: updated, profile: "Default profile").count == 2)
    }
}

@Suite struct DeviceScopeTests {
    @Test func addsToAnExistingDeviceEntry() throws {
        let config = TestConfig.fixture("typical")
        let updated = try RebindEditor.setRebind(
            in: config, profile: "Default profile", from: .key("left_command"), to: .key("left_option"), scope: .device(TestConfig.keyboard))
        #expect(changedPaths(config, updated) == ["profiles[0].devices[0].simple_modifications"])
        let rebinds = RebindEditor.rebinds(in: updated, profile: "Default profile", scope: .device(TestConfig.keyboard))
        #expect(rebinds.map(\.from) == [.key("left_option"), .key("left_command")])
        #expect(RebindEditor.rebinds(in: updated, profile: "Default profile").count == 2)
    }

    @Test func createsTheDeviceEntryWithAlphabeticalIdentifiers() throws {
        let config = TestConfig.fixture("typical")
        let other = DeviceIdentifiers(vendorID: 1, productID: 2, isKeyboard: true)
        let updated = try RebindEditor.setRebind(
            in: config, profile: "Default profile", from: .key("a"), to: .key("b"), scope: .device(other))
        #expect(changedPaths(config, updated) == ["profiles[0].devices"])
        let devices = try #require(updated["profiles"]?[index: 0]?["devices"]?.arrayValue)
        #expect(devices.count == 3)
        #expect(devices[2] == [
            "identifiers": ["is_keyboard": true, "product_id": 2, "vendor_id": 1],
            "simple_modifications": [["from": ["key_code": "a"], "to": [["key_code": "b"]]]],
        ])
    }

    @Test func aNewMouseEntryIsNotIgnored() throws {
        let updated = try RebindEditor.setRebind(
            in: TestConfig.fixture("minimal"), profile: "Default profile", from: .pointing("button4"), to: .key("v"),
            scope: .device(TestConfig.mouse))
        let device = try #require(updated["profiles"]?[index: 0]?["devices"]?[index: 0])
        #expect(device.members?.map(\.key) == ["identifiers", "ignore", "simple_modifications"])
        #expect(device["ignore"] == false)
        #expect(device["identifiers"] == ["is_pointing_device": true, "product_id": 49271, "vendor_id": 1133])
    }

    @Test func createsTheDevicesArrayWhenTheProfileHasNone() throws {
        let config = TestConfig.fixture("minimal")
        let updated = try RebindEditor.setRebind(
            in: config, profile: "Default profile", from: .key("a"), to: .key("b"), scope: .device(TestConfig.keyboard))
        #expect(changedPaths(config, updated) == ["profiles[0].devices"])
        #expect(RebindEditor.rebinds(in: updated, profile: "Default profile", scope: .device(TestConfig.keyboard)).count == 1)
    }

    @Test func createsTheListInsideAnExistingDeviceAndMatchesDespiteExtraIdentifierFields() throws {
        let config = TestConfig.fixture("future-keys")
        let ids = DeviceIdentifiers(vendorID: 1452, productID: 834, isKeyboard: true)
        let updated = try RebindEditor.setRebind(in: config, profile: "Stage ✦ 日本語", from: .key("a"), to: .key("b"), scope: .device(ids))
        #expect(changedPaths(config, updated) == ["profiles[0].devices[0].simple_modifications"])
        let device = try #require(updated["profiles"]?[index: 0]?["devices"]?[index: 0])
        #expect(device.members?.last?.key == "simple_modifications")
        #expect(device["future_device_block"] == config["profiles"]?[index: 0]?["devices"]?[index: 0]?["future_device_block"])
    }

    @Test func deviceFlagsDecideTheMatch() throws {
        let config = TestConfig.fixture("typical")
        let notAKeyboard = DeviceIdentifiers(vendorID: 1452, productID: 834)
        let updated = try RebindEditor.setRebind(
            in: config, profile: "Default profile", from: .key("a"), to: .key("b"), scope: .device(notAKeyboard))
        #expect(updated["profiles"]?[index: 0]?["devices"]?.arrayValue?.count == 3)
    }

    @Test func removingFromAMissingDeviceCreatesNothing() throws {
        let config = TestConfig.fixture("typical")
        let ids = DeviceIdentifiers(vendorID: 9, productID: 9, isKeyboard: true)
        #expect(try RebindEditor.removeRebind(in: config, profile: "Default profile", from: .key("a"), scope: .device(ids)) == config)
    }

    @Test func allDevicesAndDeviceRebindsDoNotMix() throws {
        let config = TestConfig.fixture("minimal")
        let a = try RebindEditor.setRebind(in: config, profile: "Default profile", from: .key("a"), to: .key("b"))
        let b = try RebindEditor.setRebind(in: a, profile: "Default profile", from: .key("a"), to: .key("c"), scope: .device(TestConfig.keyboard))
        #expect(RebindEditor.rebinds(in: b, profile: "Default profile").map(\.to) == [.key("b")])
        #expect(RebindEditor.rebinds(in: b, profile: "Default profile", scope: .device(TestConfig.keyboard)).map(\.to) == [.key("c")])
    }
}
