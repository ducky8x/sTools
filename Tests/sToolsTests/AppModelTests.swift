import Foundation
import STDesign
import STPlatform
import Testing
@testable import sTools

@MainActor
@Suite("AppModel")
struct AppModelTests {
    private let switchTools = ToolID.allCases.filter(\.hasSwitch)

    @Test func everyToolStartsOffAndUntouched() {
        let harness = Harness()
        for tool in ToolID.allCases { #expect(!harness.model.isOn(tool)) }
        for controller in harness.controllers.values { #expect(controller.calls.isEmpty) }
        #expect(harness.model.route == .home)
        #expect(harness.model.status(of: .crosshair) == .off)
        #expect(harness.model.status(of: .keyRebinder) == .alwaysAvailable)
    }

    @Test func flippingASwitchDrivesItsController() throws {
        let harness = Harness()
        harness.model.setTool(.crosshair, on: true)
        #expect(harness.model.isOn(.crosshair))
        #expect(harness.model.status(of: .crosshair) == .on)
        #expect(try #require(harness.controllers[.crosshair]).calls == [true])
        harness.model.setTool(.crosshair, on: false)
        #expect(!harness.model.isOn(.crosshair))
        #expect(try #require(harness.controllers[.crosshair]).calls == [true, false])
    }

    @Test func switchBindingReadsAndWrites() {
        let harness = Harness()
        let binding = harness.model.switchBinding(.windowBackdrop)
        #expect(!binding.wrappedValue)
        binding.wrappedValue = true
        #expect(harness.model.isOn(.windowBackdrop))
        #expect(binding.wrappedValue)
    }

    @Test func withoutAccessibilityNoToolCanBeSwitchedOn() {
        let harness = Harness(accessibility: .denied)
        for tool in switchTools {
            #expect(!harness.model.canSwitch(tool))
            #expect(harness.model.status(of: tool) == .needsAccessibility)
            harness.model.setTool(tool, on: true)
            #expect(!harness.model.isOn(tool))
        }
        for controller in harness.controllers.values { #expect(controller.calls.isEmpty) }
    }

    @Test func withAccessibilityEverySwitchIsAvailable() {
        let harness = Harness()
        for tool in switchTools { #expect(harness.model.canSwitch(tool)) }
    }

    @Test func keyRebinderNeverHasASwitchAndIgnoresAccessibility() {
        for accessibility in [PermissionStatus.granted, .denied] {
            let harness = Harness(accessibility: accessibility)
            #expect(!harness.model.canSwitch(.keyRebinder))
            #expect(harness.model.status(of: .keyRebinder) == .alwaysAvailable)
            harness.model.setTool(.keyRebinder, on: true)
            #expect(!harness.model.isOn(.keyRebinder))
        }
    }

    @Test func revokingAccessibilityTurnsRunningToolsOff() throws {
        let harness = Harness()
        harness.model.setTool(.nbbOverlay, on: true)
        harness.model.setTool(.crosshair, on: true)
        harness.prober.set(.accessibility, .denied)
        harness.model.permissions.refresh()
        harness.model.reconcileAccessibility()
        for tool in switchTools { #expect(!harness.model.isOn(tool)) }
        #expect(try #require(harness.controllers[.nbbOverlay]).calls == [true, false])
        #expect(try #require(harness.controllers[.crosshair]).calls == [true, false])
        #expect(try #require(harness.controllers[.windowBackdrop]).calls.isEmpty)
        #expect(harness.model.status(of: .crosshair) == .needsAccessibility)
    }

    @Test func revocationIsNoticedWithoutAnyPageOpen() async {
        let harness = Harness()
        harness.model.setTool(.windowBackdrop, on: true)
        harness.prober.set(.accessibility, .denied)
        harness.model.permissions.refresh()
        let turnedOff = await waitUntil { !harness.model.isOn(.windowBackdrop) }
        #expect(turnedOff)
    }

    @Test func grantingAccessibilityRefreshesMinecraft() async {
        let harness = Harness(accessibility: .denied)
        harness.source.instances = [fakeInstance()]
        #expect(harness.model.minecraft.active == nil)
        harness.prober.set(.accessibility, .granted)
        harness.model.permissions.refresh()
        let found = await waitUntil { harness.model.minecraft.active != nil }
        #expect(found)
    }

    @Test func permissionPollingIsHeldOnlyWhileAToolRuns() {
        let harness = Harness()
        #expect(!harness.model.isPollingForTools)
        harness.model.setTool(.crosshair, on: true)
        #expect(harness.model.isPollingForTools)
        harness.model.setTool(.nbbOverlay, on: true)
        harness.model.setTool(.crosshair, on: false)
        #expect(harness.model.isPollingForTools)
        harness.model.setTool(.nbbOverlay, on: false)
        #expect(!harness.model.isPollingForTools)
    }

    @Test func allowAccessibilityRequestsThenOpensSettingsWhenStillMissing() async {
        let harness = Harness(accessibility: .denied)
        await harness.model.allowAccessibility()
        #expect(harness.prober.requested == [.accessibility])
        #expect(harness.opened.urls == [Permission.accessibility.settingsURL])
    }

    @Test func allowAccessibilityDoesNotOpenSettingsOnceGranted() async {
        let harness = Harness(accessibility: .granted)
        await harness.model.allowAccessibility()
        #expect(harness.opened.urls.isEmpty)
    }

    @Test func navigationKeepsHistoryAndRespectsGoCommands() {
        let harness = Harness()
        let model = harness.model
        model.perform(.tool(.crosshair))
        #expect(model.route == .tool(.crosshair))
        model.perform(.settings)
        #expect(model.route == .settings)
        #expect(model.canGoBack)
        model.perform(.back)
        #expect(model.route == .tool(.crosshair))
        #expect(model.canGoForward)
        model.perform(.forward)
        #expect(model.route == .settings)
        model.perform(.home)
        #expect(model.route == .home)
        model.perform(.forward)
        #expect(model.route == .home)
    }

    @Test func changingAppearanceUpdatesTheThemeAndPersists() async {
        let harness = Harness()
        harness.model.updateAppearance { $0.soundVolume = 0.4; $0.motionMode = .reduced; $0.textScale = 1.2 }
        #expect(harness.model.theme.soundVolume == 0.4)
        #expect(harness.model.theme.motionMode == .reduced)
        #expect(harness.model.theme.textScale == 1.2)
        #expect(harness.model.appearance.soundVolume == 0.4)
        await harness.store.flush()
        let stored = SettingsStore(directory: harness.directory).load(AppearanceSettings.self)
        #expect(stored.soundVolume == 0.4)
        #expect(stored.motionMode == .reduced)
        #expect(stored.textScale == 1.2)
    }

    @Test func appearanceSavedByAnEarlierRunIsLoadedAtLaunch() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        var saved = AppearanceSettings()
        saved.soundsEnabled = false
        saved.accentHex = "#7DBF86"
        store.save(saved)
        let services = ToolServices(settings: store, displays: DisplayDirectory(),
                                    minecraft: MinecraftLocator(source: StaticMinecraftWindowSource()),
                                    permissions: PermissionCenter(prober: FakeProber(), openURL: { _ in }))
        let model = AppModel(services: services, theme: STTheme(), sound: .silent, controllers: [:], hotkeyRegistrar: FakeHotkeyRegistrar(),
                             hotkeyHUD: FakeHotkeyHUD(), loginItem: FakeLoginItem())
        #expect(!model.theme.soundsEnabled)
        #expect(model.theme.accentHex == "#7DBF86")
    }

    @Test func accentThatIsTooDarkIsStoredAsTheSanitizedColor() {
        let harness = Harness()
        harness.model.updateAppearance { $0.accentHex = "#101010" }
        #expect(harness.model.appearance.accentHex == harness.model.theme.accentHex)
        #expect(STPalette.contrastRatio(harness.model.appearance.accentHex, STPalette.background) >= 4.5)
    }

    @Test func shuttingDownTurnsEverythingOff() async throws {
        let harness = Harness()
        harness.model.setTool(.nbbOverlay, on: true)
        harness.model.setTool(.crosshair, on: true)
        await harness.model.shutDown()
        for tool in switchTools { #expect(!harness.model.isOn(tool)) }
        #expect(try #require(harness.controllers[.nbbOverlay]).calls == [true, false])
        #expect(try #require(harness.controllers[.windowBackdrop]).calls.isEmpty)
    }
}
