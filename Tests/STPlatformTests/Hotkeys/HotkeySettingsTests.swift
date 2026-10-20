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
