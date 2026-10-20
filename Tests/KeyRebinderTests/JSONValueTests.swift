import Foundation
import Testing
@testable import KeyRebinder

@Suite struct JSONParserTests {
    @Test func parsesScalars() throws {
        #expect(try JSONValue.parse("null") == .null)
        #expect(try JSONValue.parse("true") == .bool(true))
        #expect(try JSONValue.parse(" false ") == .bool(false))
        #expect(try JSONValue.parse("\"a\"") == .string("a"))
        #expect(try JSONValue.parse("12") == .int(12))
    }

    @Test func numbersKeepTheirExactText() throws {
        let value = try JSONValue.parse("[1, 1.0, 18446744073709551615, -0.5E+3, 1e-7, 0, -0]")
        let literals = value.arrayValue?.compactMap { $0.numberValue?.literal }
        #expect(literals == ["1", "1.0", "18446744073709551615", "-0.5E+3", "1e-7", "0", "-0"])
        #expect(value[index: 0] != value[index: 1])
        #expect(value[index: 0]?.semanticallyEquals(value[index: 1] ?? .null) == true)
        #expect(value[index: 2]?.numberValue?.intValue == nil)
    }

    @Test func rejectsBadNumbers() {
        for text in ["01", "1.", ".5", "+1", "1e", "--1", "0x10", "NaN", "-"] {
            #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
        }
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let value = try JSONValue.parse(#""aé\n\t\"\\\/ 😀 A""#)
        #expect(value == .string("a\u{e9}\n\t\"\\/ \u{1F600} A"))
    }

    @Test func rejectsBrokenStrings() {
        let cases = [#""\ud83d""#, #""\ude00""#, #""\u12""#, #""\x""#, "\"abc", "\"line\nbreak\""]
        for text in cases {
            #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
        }
    }

    @Test func keepsMemberOrderAndDuplicates() throws {
        let value = try JSONValue.parse(#"{"b":1,"a":2,"b":3}"#)
        #expect(value.members?.map(\.key) == ["b", "a", "b"])
        #expect(value["b"] == .int(1))
    }

    @Test func acceptsCommentsAndByteOrderMark() throws {
        let text = "\u{FEFF}// leading\n{ /* inline */ \"a\": 1, // trailing\n \"b\": [2] }"
        let value = try JSONValue.parse(text)
        #expect(value == ["a": 1, "b": [2]])
        #expect(JSONValue.containsComments(text))
        #expect(!JSONValue.containsComments(#"{"url": "http://x//y /* not a comment */"}"#))
    }

    @Test func reportsPositions() {
        do {
            _ = try JSONValue.parse("{\n  \"a\": [1,\n  oops]\n}")
            Issue.record("expected a parse error")
        } catch let error as JSONParseError {
            #expect(error.line == 3)
            #expect(error.column == 3)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func rejectsTrailingGarbageEmptyAndTrailingCommas() {
        for text in ["", "   ", "{} x", "[1,]", "{\"a\":1,}", "{\"a\" 1}", "[1 2]", "{1:2}", "/* open"] {
            #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
        }
    }

    @Test func limitsNestingDepth() {
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(throws: JSONParseError.self) { try JSONValue.parse(deep) }
        let fine = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        #expect(throws: Never.self) { try JSONValue.parse(fine) }
    }

    @Test func parsesData() throws {
        let value = try JSONValue.parse(data: Data(#"{"a":"é"}"#.utf8))
        #expect(value["a"] == .string("é"))
        #expect(throws: JSONParseError.self) { try JSONValue.parse(data: Data([0x7B, 0xFF, 0x7D])) }
    }
}

@Suite struct JSONSerializerTests {
    @Test func writesKarabinerStyle() {
        let value: JSONValue = [
            "empty_array": [],
            "empty_object": [:],
            "scalars": [1, "two", true, nil],
            "single": ["key": "value"],
            "nested_single": ["a": ["b": ["c": "d"]]],
            "array_of_objects": [["k": 1], ["k": 2]],
            "array_of_one_object": [["k": 1]],
            "array_in_array": [[1, 2]],
            "object_with_array": ["list": [1, 2]],
            "pair": ["x": 1, "y": ["z": 2]],
        ]
        let expected = """
        {
            "empty_array": [],
            "empty_object": {},
            "scalars": [1, "two", true, null],
            "single": { "key": "value" },
            "nested_single": { "a": { "b": { "c": "d" } } },
            "array_of_objects": [
                { "k": 1 },
                { "k": 2 }
            ],
            "array_of_one_object": [{ "k": 1 }],
            "array_in_array": [[1, 2]],
            "object_with_array": { "list": [1, 2] },
            "pair": {
                "x": 1,
                "y": { "z": 2 }
            }
        }
        """
        #expect(value.serialized() == expected)
    }

    @Test func forcesMultiLineForListedKeys() {
        let value: JSONValue = ["bundle_identifiers": ["^a"], "other": ["^a"]]
        let expected = """
        {
            "bundle_identifiers": [
                "^a"
            ],
            "other": ["^a"]
        }
        """
        #expect(value.serialized() == expected)
        #expect(JSONValue.object([JSONMember("bundle_identifiers", ["^a"])]).serialized() == "{\n    \"bundle_identifiers\": [\n        \"^a\"\n    ]\n}")
    }

    @Test func escapesStringsLikeKarabiner() {
        let value = JSONValue.string("q\" b\\ n\n t\t r\r b\u{8} f\u{c} c\u{1} \u{7f} é ✦ \u{1F600}")
        #expect(value.serialized() == #""q\" b\\ n\n t\t r\r b\b f\f c\u0001 "# + "\u{7f} é ✦ \u{1F600}\"")
    }

    @Test func writesNoTrailingNewline() {
        #expect(JSONValue.object([]).serialized() == "{}")
        #expect(!JSONValue.array([1, 2]).serialized().hasSuffix("\n"))
    }

    @Test func buildsNumbers() {
        #expect(JSONValue.double(1).serialized() == "1.0")
        #expect(JSONValue.double(0.25).serialized() == "0.25")
        #expect(JSONValue.int(-7).serialized() == "-7")
        #expect(JSONValue.double(.nan).serialized() == "0")
        #expect(JSONNumber(literal: "1.50")?.literal == "1.50")
        #expect(JSONNumber(literal: "abc") == nil)
    }
}

@Suite struct JSONRoundTripTests {
    @Test(arguments: FixtureLoader.names)
    func fixturesSerializeToTheirOwnBytes(name: String) throws {
        let text = FixtureLoader.text(name)
        #expect(try JSONValue.parse(text).serialized() == text)
    }

    @Test(arguments: FixtureLoader.names)
    func parseSerializeParseIsIdentical(name: String) throws {
        let first = try JSONValue.parse(FixtureLoader.text(name))
        let second = try JSONValue.parse(first.serialized())
        #expect(first == second)
    }

    @Test func semanticRoundTripSurvivesAwkwardInput() throws {
        let text = """
        {"z":[],"a":{"k":"\\u00e9\\ud83d\\ude00","n":1.0,"i":1,"big":123456789012345678901234567890,"e":2E10},
         "dup":1,"dup":2, "t":true,"nul":null,"s":"line\\nbreak","slash":"a\\/b"}
        """
        let first = try JSONValue.parse(text)
        let second = try JSONValue.parse(first.serialized())
        #expect(first == second)
        #expect(second["a"]?["n"]?.numberValue?.literal == "1.0")
        #expect(second["a"]?["big"]?.numberValue?.literal == "123456789012345678901234567890")
        #expect(second.members?.map(\.key) == ["z", "a", "dup", "dup", "t", "nul", "s", "slash"])
    }

    @Test func editingOneNodeLeavesEverythingElseUntouched() throws {
        let original = try JSONValue.parse(FixtureLoader.text("future-keys"))
        let edited = original.updating("profiles") { profiles in
            guard let profile = profiles?[index: 0] else { return profiles }
            return profiles?.replacing(at: 0, with: profile.setting("name", "Renamed"))
        }
        #expect(edited["profiles"]?[index: 0]?["name"] == "Renamed")
        let expected = original.updating("profiles") { profiles in
            let profile = profiles?[index: 0]
            var members = profile?.members ?? []
            members[1].value = "Renamed"
            return .array([.object(members)])
        }
        #expect(edited == expected)
        #expect(edited.members?.map(\.key) == original.members?.map(\.key))
        let reparsed = try JSONValue.parse(edited.serialized())
        #expect(reparsed == edited)
    }
}

@Suite struct JSONUpdateTests {
    @Test func settingReplacesInPlaceAppendsAndRemoves() {
        let value: JSONValue = ["a": 1, "b": 2]
        #expect(value.setting("a", 9) == ["a": 9, "b": 2])
        #expect(value.setting("c", 3) == ["a": 1, "b": 2, "c": 3])
        #expect(value.setting("a", nil) == ["b": 2])
        #expect(value.setting("zzz", nil) == value)
        #expect(JSONValue.int(1).setting("a", 1) == .int(1))
    }

    @Test func arrayHelpers() {
        let value: JSONValue = [1, 2, 3]
        #expect(value.appending(4) == [1, 2, 3, 4])
        #expect(value.removing(at: 1) == [1, 3])
        #expect(value.removing(at: 9) == value)
        #expect(value.replacing(at: 0, with: "x") == ["x", 2, 3])
        #expect(value.replacing(at: 9, with: "x") == value)
        #expect(value[index: 5] == nil)
    }

    @Test func semanticEqualityIgnoresMemberOrder() {
        let a: JSONValue = ["x": 1, "y": ["p": true, "q": [1, 2]]]
        let b: JSONValue = ["y": ["q": [1, 2], "p": true], "x": 1]
        #expect(a != b)
        #expect(a.semanticallyEquals(b))
        #expect(!a.semanticallyEquals(["x": 1, "y": ["p": true, "q": [2, 1]]]))
        #expect(!a.semanticallyEquals(["x": 1]))
    }
}
