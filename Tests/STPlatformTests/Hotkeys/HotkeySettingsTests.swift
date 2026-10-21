import Foundation
import Testing
@testable import STPlatform

@Suite("HotkeySettings")
struct HotkeySettingsTests {
    @Test func identityAndDefaults() {
        #expect(HotkeySettings.name == "hotkeys")
        #expect(HotkeySettings.version == 1)
        #expect(HotkeySettings.defaultValue.isEnabled == false)
        #expect(HotkeySettings.defaultValue.bindings.isEmpty)
        #expect(HotkeySettings.defaultValue.showsConfirmation)
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

    @Test func missingKeysFallBackToDefaults() throws {
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data("{}".utf8))
        #expect(settings == .defaultValue)
    }

    // MARK: Pause setting

    @Test func thePauseSettingDefaultsOnAndRoundTrips() throws {
        #expect(HotkeySettings.defaultValue.pausesWhileSToolsIsActive)
        let older = #"{"isEnabled":true,"bindings":[],"showsConfirmation":false}"#
        #expect(try JSONDecoder().decode(HotkeySettings.self, from: Data(older.utf8)).pausesWhileSToolsIsActive)

        let value = HotkeySettings(isEnabled: true, bindings: [], showsConfirmation: true, pausesWhileSToolsIsActive: false)
        let data = try JSONEncoder().encode(value)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["pausesWhileSToolsIsActive"] as? Bool == false)
        #expect(try JSONDecoder().decode(HotkeySettings.self, from: data) == value)
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
        #expect(try JSONDecoder().decode(HotkeySettings.self, from: Data(allWrong.utf8)) == .defaultValue)

        let oneWrong = #"{"isEnabled":true,"showsConfirmation":false,"pausesWhileSToolsIsActive":false,"bindings":"oops"}"#
        let settings = try JSONDecoder().decode(HotkeySettings.self, from: Data(oneWrong.utf8))
        #expect(settings == HotkeySettings(isEnabled: true, bindings: [], showsConfirmation: false, pausesWhileSToolsIsActive: false))
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
        ])

        let writer = SettingsStore(directory: directory)
        writer.save(value)
        await writer.flush()

        #expect(SettingsStore(directory: directory).load(HotkeySettings.self) == value)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "hotkeys.json").path))
    }
}
