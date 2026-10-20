import Foundation
import Testing
@testable import KeyRebinder

@Suite struct KarabinerConfigTests {
    @Test func readsProfilesInOrder() throws {
        let config = KarabinerConfig(root: try JSONValue.parse(FixtureLoader.text("typical")))
        #expect(config.profiles.map(\.name) == ["Default profile", "Plain keyboard", "Macros"])
        #expect(config.profiles.map(\.isSelected) == [true, false, false])
        #expect(config.selectedProfileName == "Default profile")
        #expect(config.profiles[1].json["virtual_hid_keyboard"]?["keyboard_type_v2"] == "iso")
    }

    @Test func selectedProfileIsTheFirstMarkedOne() throws {
        let root = try JSONValue.parse(#"{"profiles":[{"name":"a"},{"name":"b","selected":true},{"name":"c","selected":true}]}"#)
        #expect(KarabinerConfig(root: root).selectedProfileName == "b")
    }

    @Test func fallsBackToTheFirstProfileWhenNoneIsSelected() throws {
        let root = try JSONValue.parse(#"{"profiles":[{"name":"a"},{"name":"b"}]}"#)
        #expect(KarabinerConfig(root: root).selectedProfileName == "a")
    }

    @Test func missingProfilesGiveNoNames() throws {
        let config = KarabinerConfig(root: try JSONValue.parse(#"{"global":{}}"#))
        #expect(config.profiles.isEmpty)
        #expect(config.selectedProfileName == nil)
    }

    @Test func unnamedProfileHasAnEmptyName() throws {
        let config = KarabinerConfig(root: try JSONValue.parse(#"{"profiles":[{"selected":true,"name":5}]}"#))
        #expect(config.profiles[0].name == "")
        #expect(config.selectedProfileName == "")
    }

    @Test func keepsUnicodeNames() throws {
        let config = KarabinerConfig(root: try JSONValue.parse(FixtureLoader.text("future-keys")))
        #expect(config.selectedProfileName == "Stage ✦ 日本語")
    }
}
