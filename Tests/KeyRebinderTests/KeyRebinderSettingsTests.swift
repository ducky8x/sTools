import Foundation
import Testing
@testable import KeyRebinder

@Suite struct KeyRebinderSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = KeyRebinderSettings.defaultValue
        #expect(settings.keyboardShape == nil && settings.formFactor == nil && settings.layout == nil)
        #expect(settings.scope == .allDevices)
        #expect(settings.showsMinecraftKeybinds)
        #expect(settings.customOptionsFilePath == nil)
        #expect(settings.checkerEnabled && settings.checkerIncludesSpeedrunRules)
        #expect(settings.showsHoverArcs)
        #expect(settings.backupsKept == 20)
        #expect(KeyRebinderSettings.name == "keyRebinder")
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = KeyRebinderSettings.defaultValue
        settings.keyboardShape = .iso
        settings.formFactor = .fullSize
        settings.scopeDevice = DeviceIdentifiers(vendorID: 1133, productID: 49271, isPointingDevice: true)
        settings.customOptionsFilePath = "/tmp/options.txt"
        settings.checkerIncludesSpeedrunRules = false
        settings.backupsKept = 50
        let decoded = try JSONDecoder().decode(KeyRebinderSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.layout == KeyboardLayout(shape: .iso, formFactor: .fullSize))
        #expect(decoded.scope == .device(DeviceIdentifiers(vendorID: 1133, productID: 49271, isPointingDevice: true)))
    }

    @Test func badValuesFallBackAndCountsAreClamped() throws {
        let json = #"{"keyboardShape": "dvorak", "formFactor": 3, "backupsKept": 0, "showsHoverArcs": "yes", "customOptionsFilePath": ""}"#
        let decoded = try JSONDecoder().decode(KeyRebinderSettings.self, from: Data(json.utf8))
        #expect(decoded.keyboardShape == nil && decoded.formFactor == nil)
        #expect(decoded.backupsKept == 1)
        #expect(decoded.showsHoverArcs)
        #expect(decoded.customOptionsFilePath == nil)
    }
}
