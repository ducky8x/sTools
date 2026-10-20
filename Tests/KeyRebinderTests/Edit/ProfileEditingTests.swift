import Testing
@testable import KeyRebinder

@Suite struct ProfileEditingTests {
    let typical = TestConfig.fixture("typical")

    func selectedFlags(_ config: JSONValue) -> [Bool?] {
        (config["profiles"]?.arrayValue ?? []).map { $0["selected"]?.boolValue }
    }

    @Test func listsNamesAndTheSelectedProfile() {
        #expect(RebindEditor.profileNames(in: typical) == ["Default profile", "Plain keyboard", "Macros"])
        #expect(RebindEditor.selectedProfileName(in: typical) == "Default profile")
        let none = TestConfig.parse(#"{ "profiles": [{ "name": "A" }, { "name": "B" }] }"#)
        #expect(RebindEditor.selectedProfileName(in: none) == "A")
        #expect(RebindEditor.selectedProfileName(in: TestConfig.parse("{}")) == nil)
    }

    @Test func uniqueNamesCountUp() {
        #expect(RebindEditor.uniqueProfileName("Fresh", in: typical) == "Fresh")
        #expect(RebindEditor.uniqueProfileName("Macros", in: typical) == "Macros 2")
        let crowded = TestConfig.parse(#"{ "profiles": [{ "name": "A" }, { "name": "A 2" }, { "name": "A 3" }] }"#)
        #expect(RebindEditor.uniqueProfileName("A", in: crowded) == "A 4")
        #expect(RebindEditor.suggestedCopyName(of: "Macros", in: typical) == "Macros (copy)")
        let withCopy = try! RebindEditor.duplicateProfile(in: typical, name: "Macros", as: "Macros (copy)")
        #expect(RebindEditor.suggestedCopyName(of: "Macros", in: withCopy) == "Macros (copy) 2")
    }

    @Test(arguments: FixtureLoader.names)
    func createsAnEmptyUnselectedProfile(fixture: String) throws {
        let config = TestConfig.fixture(fixture)
        let updated = try RebindEditor.createEmptyProfile(in: config, name: "  Speedrun  ")
        let profiles = try #require(updated["profiles"]?.arrayValue)
        #expect(profiles.last == ["name": "Speedrun", "selected": false])
        #expect(RebindEditor.selectedProfileName(in: updated) == RebindEditor.selectedProfileName(in: config))
        #expect(changedPaths(config, updated) == ["profiles"])
        #expect(Array(profiles.dropLast()) == config["profiles"]?.arrayValue)
    }

    @Test func refusesEmptyAndTakenNames() {
        #expect(throws: EditError.emptyProfileName) { try RebindEditor.createEmptyProfile(in: typical, name: "   ") }
        #expect(throws: EditError.profileNameTaken("Macros")) { try RebindEditor.createEmptyProfile(in: typical, name: "Macros") }
        #expect(throws: EditError.profileNameTaken("Macros")) { try RebindEditor.duplicateProfile(in: typical, name: "Plain keyboard", as: " Macros ") }
    }

    @Test func duplicatesEverythingExceptNameAndSelection() throws {
        let updated = try RebindEditor.duplicateProfile(in: typical, name: "Default profile", as: "Copy")
        let profiles = try #require(updated["profiles"]?.arrayValue)
        #expect(profiles.count == 4)
        let original = profiles[0]
        let copy = profiles[3]
        #expect(copy["name"] == "Copy")
        #expect(copy["selected"] == false)
        #expect(copy.members?.map(\.key) == original.members?.map(\.key))
        #expect(changedPaths(original, copy) == ["name", "selected"])
        #expect(original["selected"] == true)
        #expect(Array(profiles.prefix(3)) == typical["profiles"]?.arrayValue)
    }

    @Test func duplicatingAnUnselectedProfileKeepsItsFlagAbsent() throws {
        let config = TestConfig.parse(#"{ "profiles": [{ "name": "A", "selected": true }, { "name": "B" }] }"#)
        let updated = try RebindEditor.duplicateProfile(in: config, name: "B", as: "C")
        #expect(updated["profiles"]?[index: 2] == ["name": "C"])
        #expect(throws: EditError.profileNotFound("Z")) { try RebindEditor.duplicateProfile(in: config, name: "Z", as: "Y") }
    }

    @Test func renamesWithoutTouchingAnythingElse() throws {
        let updated = try RebindEditor.renameProfile(in: typical, name: "Default profile", to: "Main")
        #expect(changedPaths(typical, updated) == ["profiles[0].name"])
        #expect(RebindEditor.selectedProfileName(in: updated) == "Main")
        #expect(try RebindEditor.renameProfile(in: typical, name: "Macros", to: "Macros") == typical)
    }

    @Test func renameRefusals() {
        #expect(throws: EditError.profileNameTaken("Macros")) { try RebindEditor.renameProfile(in: typical, name: "Plain keyboard", to: "Macros") }
        #expect(throws: EditError.emptyProfileName) { try RebindEditor.renameProfile(in: typical, name: "Plain keyboard", to: "") }
        #expect(throws: EditError.profileNotFound("Nope")) { try RebindEditor.renameProfile(in: typical, name: "Nope", to: "X") }
    }

    @Test func deletesAnotherProfile() throws {
        let updated = try RebindEditor.deleteProfile(in: typical, name: "Plain keyboard")
        #expect(RebindEditor.profileNames(in: updated) == ["Default profile", "Macros"])
        #expect(changedPaths(typical, updated) == ["profiles"])
    }

    @Test func refusesToDeleteTheSelectedProfile() {
        #expect(throws: EditError.cannotDeleteSelectedProfile("Default profile")) {
            try RebindEditor.deleteProfile(in: typical, name: "Default profile")
        }
        let onlyOne = TestConfig.fixture("minimal")
        #expect(throws: EditError.cannotDeleteSelectedProfile("Default profile")) {
            try RebindEditor.deleteProfile(in: onlyOne, name: "Default profile")
        }
        let implicit = TestConfig.parse(#"{ "profiles": [{ "name": "A" }, { "name": "B" }] }"#)
        #expect(throws: EditError.cannotDeleteSelectedProfile("A")) { try RebindEditor.deleteProfile(in: implicit, name: "A") }
        #expect(throws: EditError.profileNotFound("Nope")) { try RebindEditor.deleteProfile(in: typical, name: "Nope") }
    }

    @Test func movesProfilesToAnIndex() throws {
        let updated = try RebindEditor.moveProfile(in: typical, from: 2, to: 0)
        #expect(RebindEditor.profileNames(in: updated) == ["Macros", "Default profile", "Plain keyboard"])
        #expect(RebindEditor.selectedProfileName(in: updated) == "Default profile")
        #expect(try RebindEditor.moveProfile(in: typical, from: 1, to: 1) == typical)
        #expect(throws: EditError.profileIndexOutOfRange(3)) { try RebindEditor.moveProfile(in: typical, from: 0, to: 3) }
        #expect(throws: EditError.profileIndexOutOfRange(-1)) { try RebindEditor.moveProfile(in: typical, from: -1, to: 0) }
    }

    @Test func selectingKeepsExactlyOneSelectedFlag() throws {
        let updated = try RebindEditor.selectProfile(in: typical, name: "Macros")
        #expect(selectedFlags(updated) == [false, false, true])
        #expect(RebindEditor.selectedProfileName(in: updated) == "Macros")
        #expect(changedPaths(typical, updated) == ["profiles[0].selected", "profiles[2].selected"])
        #expect(try RebindEditor.selectProfile(in: typical, name: "Default profile") == typical)
    }

    @Test func selectingFixesInconsistentFlags() throws {
        let messy = TestConfig.parse(#"{ "profiles": [{ "name": "A", "selected": true }, { "name": "B" }, { "name": "C", "selected": true }] }"#)
        let updated = try RebindEditor.selectProfile(in: messy, name: "B")
        #expect(selectedFlags(updated) == [false, true, false])
        let none = TestConfig.parse(#"{ "profiles": [{ "name": "A" }, { "name": "B" }] }"#)
        #expect(selectedFlags(try RebindEditor.selectProfile(in: none, name: "B")) == [nil, true])
        #expect(throws: EditError.profileNotFound("Z")) { try RebindEditor.selectProfile(in: messy, name: "Z") }
    }

    @Test func selectedProfilesBecomeDeletableOnceAnotherIsSelected() throws {
        let switched = try RebindEditor.selectProfile(in: typical, name: "Macros")
        let updated = try RebindEditor.deleteProfile(in: switched, name: "Default profile")
        #expect(RebindEditor.profileNames(in: updated) == ["Plain keyboard", "Macros"])
    }
}
