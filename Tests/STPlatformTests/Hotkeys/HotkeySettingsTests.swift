import Foundation
import Testing
@testable import STPlatform

@Suite("HotkeySettings")
struct HotkeySettingsTests {
    /// A new install (no `hotkeys.json`) has ⌘1–⌘5 with hotkeys on: by default they work only in sTools and
    /// Minecraft, so they take no other app's keys. A value built in code starts off and empty, as before.
    @Test func identityAndDefaults() {
        #expect(HotkeySettings.name == "hotkeys")
        #expect(HotkeySettings.version == 1)
        #expect(HotkeySettings.defaultValue.isEnabled, "a new install starts with hotkeys on")
        #expect(HotkeySettings.defaultValue.bindings.map(\.combo) == HotkeyKeySet.command.combos, "a new install's ⌘1–⌘5")
        #expect(HotkeySettings.defaultValue.showsConfirmation)
        #expect(HotkeySettings.defaultValue.scope == .sToolsAndMinecraft)
        #expect(!HotkeySettings().isEnabled)
        #expect(HotkeySettings().bindings.isEmpty)
    }

    /// Documents saved before the confirmation setting existed keep their switch and bindings, and get it on.
    @Test func olderDocumentsWithoutShowsConfirmationDecodeWithItOn() throws {
        let json = """
        {"isEnabled":true,"bindings":[{"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F",
         "combo":{"keyCode":8,"modifiers":6144},"actions":["toggle.crosshair"]}]}
        """
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
        #expect(settings.isEnabled)
        #expect(settings.bindings.count == 1)
        #expect(settings.showsConfirmation)
    }

    @Test func showsConfirmationOffRoundTrips() throws {
        let value = HotkeySettings(isEnabled: true, bindings: [], showsConfirmation: false)
        let decoded = try JSONDecoder().decode(HotkeySettings.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func bindingDropsRepeatedActionsKeepingOrder() {
        let binding = HotkeyBinding(combo: HotkeyCombo(keyCode: 8, modifiers: [.control, .option]),
                                    actions: [.toggle(.nbbOverlay), .toggle(.crosshair), .toggle(.nbbOverlay)])
        #expect(binding.actions == [.toggle(.nbbOverlay), .toggle(.crosshair)])
    }

    @Test func decodingDropsRepeatedActionsToo() throws {
        let json = """
        {"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F","combo":{"keyCode":8,"modifiers":6144},
         "actions":["toggle.crosshair","toggle.crosshair","startStopRecording"]}
        """
        let binding = try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        #expect(binding.actions == [.toggle(.crosshair), .startStopRecording])
    }

    /// A file that exists keeps what it has: without a list it has none, and gets no new install's key set.
    @Test func missingKeysFallBackToDefaults() throws {
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data("{}".utf8))
        #expect(settings == HotkeySettings())
    }

    // MARK: Where hotkeys work

    @Test func scopeDefaultsToSToolsAndMinecraft() {
        #expect(HotkeySettings.defaultValue.scope == .sToolsAndMinecraft)
        #expect(HotkeySettings().scope == .sToolsAndMinecraft)
    }

    /// Every file from before the setting existed has no `scope`; it gets the default and keeps everything else.
    @Test func filesWithoutScopeGetTheDefault() throws {
        let older = """
        {"isEnabled":true,"showsConfirmation":false,"bindings":[{"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F",
         "combo":{"keyCode":8,"modifiers":6144},"actions":["toggle.crosshair"]}]}
        """
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data(older.utf8))
        #expect(settings.scope == .sToolsAndMinecraft)
        #expect(settings.isEnabled)
        #expect(!settings.showsConfirmation)
        #expect(settings.bindings.count == 1)
    }

    @Test func anUnknownOrWrongScopeFallsBackToTheDefaultAlone() throws {
        for scope in [#""somewhereNew""#, "3", "true", #"{"a":1}"#, "null"] {
            let json = #"{"isEnabled":true,"bindings":[],"showsConfirmation":false,"scope":\#(scope)}"#
            let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
            #expect(settings == HotkeySettings(isEnabled: true, bindings: [], showsConfirmation: false), "\(scope)")
        }
    }

    @Test func everywhereRoundTrips() throws {
        let value = HotkeySettings(isEnabled: true, bindings: [], scope: .everywhere)
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self).contains(#""scope":"everywhere""#))
        #expect(try JSONDecoder().decode(HotkeySettings.self, from: data) == value)
    }

    // MARK: The old pause setting

    /// Builds that paused hotkeys whenever sTools was in front saved `pausesWhileSToolsIsActive`, on by default.
    /// That pause was why hotkeys never fired in sTools; the key is now ignored on load and dropped on save.
    @Test func theOldPauseSettingIsIgnoredAndDropped() throws {
        let older = #"{"isEnabled":true,"bindings":[],"showsConfirmation":false,"pausesWhileSToolsIsActive":true}"#
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data(older.utf8))
        #expect(settings == HotkeySettings(isEnabled: true, bindings: [], showsConfirmation: false))

        let data = try JSONEncoder().encode(settings)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["pausesWhileSToolsIsActive"] == nil)
        #expect(Set(json.keys) == ["isEnabled", "bindings", "showsConfirmation", "scope"])
    }

    // MARK: Lossy decoding (one bad entry never costs the rest)

    @Test func unknownActionsAreDropped() throws {
        let json = """
        {"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F","combo":{"keyCode":8,"modifiers":6144},
         "actions":["toggle.hologram","toggle.crosshair","someFutureAction",7,"startStopRecording"]}
        """
        let binding = try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        #expect(binding.actions == [.toggle(.crosshair), .startStopRecording])
    }

    /// Start timer is stored as "startTimer" and survives beside an action this build doesn't know. A build without
    /// it drops it the same way and keeps the hotkey (spec 5.6.10).
    @Test func startTimerRoundTripsBesideAnUnknownAction() throws {
        let json = """
        {"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F","combo":{"keyCode":105,"modifiers":0},
         "actions":["startTimer","someFutureAction","toggle.crosshair"]}
        """
        let binding = try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        #expect(binding.actions == [.startTimer, .toggle(.crosshair)])

        let data = try JSONEncoder().encode(binding)
        let stored = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(stored["actions"] as? [String] == ["startTimer", "toggle.crosshair"])
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: data) == binding)
    }

    /// The binding stays (it shows "No actions") when none of its actions is known, or its actions aren't a list.
    @Test func aBindingWithNoKnownActionIsKeptEmpty() throws {
        for actions in [#"["someFutureAction"]"#, #""toggle.crosshair""#, "null"] {
            let json = """
            {"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F","combo":{"keyCode":8,"modifiers":6144},"actions":\(actions)}
            """
            let binding = try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
            #expect(binding.actions.isEmpty, "\(actions)")
            #expect(binding.combo == HotkeyCombo(keyCode: 8, modifiers: [.control, .option]))
        }
    }

    @Test func aBindingWithABadIdOrComboIsSkipped() throws {
        let json = """
        {"isEnabled":true,"bindings":[
          {"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F","combo":{"keyCode":83,"modifiers":0},"actions":["toggle.crosshair"]},
          {"id":"not-a-uuid","combo":{"keyCode":8,"modifiers":6144},"actions":["toggle.crosshair"]},
          {"combo":{"keyCode":8,"modifiers":6144},"actions":["toggle.crosshair"]},
          {"id":"6C1D9C9F-7E1C-4F2F-8C8C-1C8D2D4E5F60","combo":{"keyCode":"C","modifiers":0},"actions":["toggle.crosshair"]},
          {"id":"7D2EAD00-8F2D-4A3A-9D9D-2D9E3E5F6071","actions":["toggle.crosshair"]},
          5,
          "loose text",
          {"id":"8E3FBE11-902E-4B4B-AEAE-3EAF4F607182","combo":{"keyCode":96,"modifiers":512},"actions":["toggle.nbbOverlay"]}
        ]}
        """
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
        #expect(settings.isEnabled)
        #expect(settings.bindings.map(\.id.uuidString) == ["5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F",
                                                           "8E3FBE11-902E-4B4B-AEAE-3EAF4F607182"])
        #expect(settings.bindings.map(\.combo) == [HotkeyCombo(keyCode: 83, modifiers: []), HotkeyCombo(keyCode: 96, modifiers: .shift)])
    }

    @Test func wrongTypesFallBackToDefaults() throws {
        let allWrong = #"{"isEnabled":"yes","showsConfirmation":3,"pausesWhileSToolsIsActive":"no","bindings":{"a":1}}"#
        #expect(try JSONDecoder().decode(HotkeySettings.self, from: Data(allWrong.utf8)) == HotkeySettings())

        let oneWrong = #"{"isEnabled":true,"showsConfirmation":false,"pausesWhileSToolsIsActive":false,"bindings":"oops"}"#
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data(oneWrong.utf8))
        #expect(settings == HotkeySettings(isEnabled: true, bindings: [], showsConfirmation: false))
    }

    /// Before lossy decoding, one bad entry made the settings store move the whole file aside.
    @MainActor
    @Test func aBrokenEntryDoesNotMoveTheFileAside() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hotkeys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = """
        {"version":1,"value":{"isEnabled":true,"bindings":[
          {"id":"5B0C8B8E-6D0B-4F1E-9B7B-0B7C1C3D4E5F","combo":{"keyCode":83,"modifiers":0},"actions":["toggle.crosshair","someFutureAction"]},
          {"id":"broken","combo":{"keyCode":8,"modifiers":6144},"actions":["toggle.crosshair"]}
        ]}}
        """
        try Data(file.utf8).write(to: directory.appending(path: "hotkeys.json"))

        let settings = SettingsStore(directory: directory).load(HotkeySettings.self)
        #expect(settings.isEnabled)
        #expect(settings.bindings.map(\.combo) == [HotkeyCombo(keyCode: 83, modifiers: [])])
        #expect(settings.bindings.first?.actions == [.toggle(.crosshair)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hotkeys.json"])
    }

    @MainActor
    @Test func roundTripsThroughTheSettingsStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hotkeys-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = HotkeySettings(isEnabled: true, bindings: [
            HotkeyBinding(combo: HotkeyCombo(keyCode: 8, modifiers: [.control, .option]),
                          actions: [.toggle(.crosshair), .toggle(.nbbOverlay), .startStopRecording]),
            HotkeyBinding(combo: HotkeyCombo(keyCode: 96, modifiers: .shift), actions: [.toggle(.windowBackdrop)]),
            HotkeyBinding(combo: HotkeyCombo(keyCode: 105, modifiers: []), actions: [.startTimer]),
        ])

        let writer = SettingsStore(directory: directory)
        writer.save(value)
        await writer.flush()

        #expect(SettingsStore(directory: directory).load(HotkeySettings.self) == value)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "hotkeys.json").path))
    }
}
