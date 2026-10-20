import Testing
@testable import KeyRebinder

@Suite struct FnFunctionKeyTests {
    @Test func defaultsApplyWhenNothingIsConfigured() {
        let keys = RebindEditor.fnFunctionKeys(in: TestConfig.fixture("minimal"), profile: "Default profile")
        #expect(keys == RebindEditor.fnFunctionKeyDefaults)
        #expect(keys.count == 12)
        #expect(keys[0] == .consumer("display_brightness_decrement"))
        #expect(keys[11] == .consumer("volume_increment"))
        #expect(RebindEditor.fnFunctionKeys(in: TestConfig.fixture("minimal"), profile: "Nope") == keys)
    }

    @Test func fileEntriesOverrideTheDefaults() {
        let keys = RebindEditor.fnFunctionKeys(in: TestConfig.fixture("typical"), profile: "Default profile")
        #expect(keys[2] == .other(["apple_vendor_keyboard_key_code": "launchpad"]))
        #expect(keys[0] == RebindEditor.fnFunctionKeyDefaults[0])
    }

    @Test func theLastEntryForAKeyWins() {
        let config = TestConfig.profile(fn: """
        [
            { "from": { "key_code": "f1" }, "to": [{ "key_code": "a" }] },
            { "from": { "key_code": "f1" }, "to": [{ "key_code": "b" }] }
        ]
        """)
        #expect(RebindEditor.fnFunctionKeys(in: config, profile: "P")[0] == .key("b"))
    }

    @Test func aDeviceEntryBeatsTheProfileEntry() {
        let config = TestConfig.profile(
            devices: """
            [{ "identifiers": { "is_keyboard": true, "product_id": 834, "vendor_id": 1452 },
               "fn_function_keys": [{ "from": { "key_code": "f2" }, "to": [{ "key_code": "x" }] }] }]
            """,
            fn: #"[{ "from": { "key_code": "f2" }, "to": [{ "key_code": "y" }] }, { "from": { "key_code": "f3" }, "to": [{ "key_code": "z" }] }]"#)
        let device = RebindEditor.fnFunctionKeys(in: config, profile: "P", scope: .device(TestConfig.keyboard))
        #expect(device[1] == .key("x"))
        #expect(device[2] == .key("z"))
        let all = RebindEditor.fnFunctionKeys(in: config, profile: "P")
        #expect(all[1] == .key("y"))
    }

    @Test(arguments: FixtureLoader.names)
    func settingCreatesOrUpdatesOnlyTheFnList(fixture: String) throws {
        let config = TestConfig.fixture(fixture)
        let profile = try #require(RebindEditor.profileNames(in: config).first)
        let updated = try RebindEditor.setFnFunctionKey(1, to: .key("escape"), in: config, profile: profile)
        #expect(RebindEditor.fnFunctionKeys(in: updated, profile: profile)[0] == .key("escape"))
        #expect(changedPaths(config, updated) == ["profiles[0].fn_function_keys"])
    }

    @Test func settingReplacesTheExistingEntryInPlace() throws {
        let config = TestConfig.fixture("typical")
        let updated = try RebindEditor.setFnFunctionKey(3, to: .key("f3"), in: config, profile: "Default profile")
        #expect(changedPaths(config, updated).allSatisfy { $0.hasPrefix("profiles[0].fn_function_keys[0].to[0]") })
        #expect(updated["profiles"]?[index: 0]?["fn_function_keys"]?.arrayValue?.count == 1)
    }

    @Test func nilRemovesTheEntryAndRestoresTheDefault() throws {
        let config = TestConfig.fixture("typical")
        let updated = try RebindEditor.setFnFunctionKey(3, to: nil, in: config, profile: "Default profile")
        #expect(RebindEditor.fnFunctionKeys(in: updated, profile: "Default profile")[2] == RebindEditor.fnFunctionKeyDefaults[2])
        #expect(updated["profiles"]?[index: 0]?["fn_function_keys"] == [])
        let minimal = TestConfig.fixture("minimal")
        #expect(try RebindEditor.setFnFunctionKey(5, to: nil, in: minimal, profile: "Default profile") == minimal)
    }

    @Test func deviceScopeCreatesTheDeviceEntry() throws {
        let config = TestConfig.fixture("minimal")
        let updated = try RebindEditor.setFnFunctionKey(
            12, to: .consumer("mute"), in: config, profile: "Default profile", scope: .device(TestConfig.keyboard))
        #expect(changedPaths(config, updated) == ["profiles[0].devices"])
        #expect(RebindEditor.fnFunctionKeys(in: updated, profile: "Default profile", scope: .device(TestConfig.keyboard))[11] == .consumer("mute"))
        #expect(RebindEditor.fnFunctionKeys(in: updated, profile: "Default profile")[11] == RebindEditor.fnFunctionKeyDefaults[11])
    }

    @Test func rejectsNumbersOutsideOneToTwelveAndUnknownProfiles() {
        let config = TestConfig.fixture("minimal")
        for number in [0, 13, -1] {
            #expect(throws: EditError.invalidFunctionKey(number)) {
                try RebindEditor.setFnFunctionKey(number, to: .key("a"), in: config, profile: "Default profile")
            }
        }
        #expect(throws: EditError.profileNotFound("Nope")) {
            try RebindEditor.setFnFunctionKey(1, to: .key("a"), in: config, profile: "Nope")
        }
    }
}
