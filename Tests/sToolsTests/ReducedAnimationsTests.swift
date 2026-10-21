import AppKit
import CoreGraphics
import Foundation
import Prologue
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

// Settings ▸ Appearance ▸ Reduce animations across the app (spec 3.4): the setting, macOS's Reduce motion, the main
// window's pages, the introduction's exit, the hotkey confirmation and the window itself. The main window is hosted
// in a window that's never ordered in, so nothing reaches a screen; a render right after a change shows whether it
// landed at once. Each reduced case has a full-motion control that must be caught mid-way. The macOS setting is
// always injected.

// MARK: - Harness

/// Never shown, and never touches the saved frame in the defaults, as the real main window would.
private final class UnshownWindow: NSWindow {
    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool { true }
    override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName) -> Bool { false }
}

@MainActor
private final class Still {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init<V: View>(_ view: V, size: CGSize = CGSize(width: 760, height: 560)) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        window = UnshownWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle()
    }

    isolated deinit {
        window.contentView = nil
    }

    /// Lets pending updates through, with as little time as possible passing for motion.
    func settle() {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        host.layoutSubtreeIfNeeded()
    }

    /// After letting every pending update through.
    func capture() -> NSBitmapImageRep {
        settle()
        return render()
    }

    /// Right away, without running the run loop, so no other work (another test's included) can let an animation
    /// get far: how a full-motion control catches a change on its way.
    func captureNow() -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        return render()
    }

    private func render() -> NSBitmapImageRep {
        let size = host.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

private func sameImage(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let left = a.bitmapData, let right = b.bitmapData else { return false }
    return memcmp(left, right, a.bytesPerRow * a.pixelsHigh) == 0
}

/// A harness with Reduce animations turned on the way the switch does it. (A theme passed to `Harness` loses its
/// motion mode: the model applies the stored Appearance over it at launch, as the app does.)
@MainActor
private func reducedHarness() -> Harness {
    let harness = Harness()
    harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
    return harness
}

/// The whole main window for a harness, as the app shows it.
@MainActor
private func window(_ harness: Harness) -> Still {
    Still(RootView(model: harness.model))
}

/// A display far outside every real one, so ordering a panel in never shows anything on screen.
private let offScreenDisplay = DisplayInfo(
    id: 998, name: "Off screen", frame: CGRect(x: -9000, y: -9000, width: 1512, height: 982),
    bounds: CGRect(x: -9000, y: 9000, width: 1512, height: 982), backingScale: 2,
    pixelSize: CGSize(width: 3024, height: 1964), isMain: false)

// MARK: - The setting

@MainActor
@Suite("Reduce animations: the setting")
struct ReduceAnimationsSettingTests {
    @Test func itIsOffByDefault() {
        let harness = Harness()
        #expect(!harness.model.appearance.reducesAnimations)
        #expect(!harness.model.theme.reduceMotion)
    }

    @Test func turningItOnAndOffAppliesLiveAndIsSaved() async {
        let harness = Harness()
        let binding = harness.model.appearanceBinding(\.reducesAnimations)

        binding.wrappedValue = true
        #expect(harness.model.theme.reduceMotion, "on at once, no relaunch")
        #expect(binding.wrappedValue)
        await harness.model.settings.flush()
        #expect(SettingsStore(directory: harness.directory).load(AppearanceSettings.self).reducesAnimations)

        binding.wrappedValue = false
        #expect(!harness.model.theme.reduceMotion)
        await harness.model.settings.flush()
        #expect(!SettingsStore(directory: harness.directory).load(AppearanceSettings.self).reducesAnimations)
    }

    @Test func turningItOnWorksWhateverMacOSSays() {
        let theme = STTheme(systemReduceMotion: false)
        let harness = Harness(theme: theme)
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        #expect(theme.reduceMotion)
    }

    @Test func macOSReduceMotionReducesWithTheSwitchOff() {
        let theme = STTheme(systemReduceMotion: true)
        let harness = Harness(theme: theme)
        #expect(!harness.model.appearance.reducesAnimations, "the switch shows the setting, not the system")
        #expect(theme.reduceMotion)
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = false
        #expect(theme.reduceMotion, "turning the switch off can't override macOS")
    }

    @Test func theNoteSaysWhenMacOSIsTheReason() {
        let off = SettingsPage.reduceAnimationsNote(systemReducesMotion: false)
        let on = SettingsPage.reduceAnimationsNote(systemReducesMotion: true)
        #expect(off != on)
        #expect(off.contains("Reduce motion"))
        #expect(on.contains("Reduce motion"))
        #expect(on.contains("off"))
    }

    @Test func otherAppearanceChangesKeepIt() {
        let harness = Harness()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        harness.model.percentBinding(\.soundVolume).wrappedValue = 30
        harness.model.appearanceBinding(\.accentHex).wrappedValue = "#7DBF86"
        #expect(harness.model.appearance.reducesAnimations)
        #expect(harness.model.theme.reduceMotion)
    }
}

// MARK: - Export, import and reset

@MainActor
@Suite("Reduce animations: export, import and reset")
struct ReduceAnimationsDataTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "reduce-\(UUID().uuidString).stools-settings")
    }

    @Test func exportCarriesIt() async throws {
        let harness = Harness()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await harness.model.exportSettings(to: file)

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let documents = try #require(root["documents"] as? [String: Any])
        let appearance = try #require(documents[AppearanceSettings.name] as? [String: Any])
        let value = try #require(appearance["value"] as? [String: Any])
        #expect(value["motionMode"] as? String == "reduced")
    }

    @Test func importAppliesItAtOnce() async throws {
        let harness = Harness()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await harness.model.exportSettings(to: file)

        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = false
        #expect(!harness.model.theme.reduceMotion)
        try await harness.model.importSettings(from: file)
        #expect(harness.model.theme.reduceMotion, "no relaunch needed")
        #expect(harness.model.appearance.reducesAnimations)
    }

    @Test func aChangeAfterAnImportKeepsTheImportedValue() async throws {
        let harness = Harness()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await harness.model.exportSettings(to: file)
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = false
        try await harness.model.importSettings(from: file)

        harness.model.percentBinding(\.soundVolume).wrappedValue = 20
        await harness.model.settings.flush()
        let stored = SettingsStore(directory: harness.directory).load(AppearanceSettings.self)
        #expect(stored.reducesAnimations, "the old in-memory value didn't overwrite the import")
        #expect(stored.soundVolume == 0.2)
    }

    @Test func importingAFileWithoutAppearanceLeavesItAlone() async throws {
        let harness = Harness()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let envelope: [String: Any] = ["format": 1, "app": "sTools", "documents": [
            GeneralSettings.name: ["version": 1, "value": ["restoreToolsAtQuit": true]],
        ]]
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        try await harness.model.importSettings(from: file)
        #expect(harness.model.theme.reduceMotion)
        #expect(harness.model.appearance.reducesAnimations)
    }

    @Test func resetTurnsItOff() async throws {
        let harness = Harness()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        await harness.model.settings.flush()
        try await harness.model.resetAppSettings()
        #expect(!SettingsStore(directory: harness.directory).load(AppearanceSettings.self).reducesAnimations)
    }
}

// MARK: - macOS's Reduce motion

@MainActor
@Suite("Reduce animations: following macOS")
struct SystemMotionWatcherTests {
    @MainActor
    final class FakeSystem {
        var reduces = false
        var reads = 0
    }

    private func watcher(_ theme: STTheme, _ system: FakeSystem, _ center: NotificationCenter) -> SystemMotionWatcher {
        SystemMotionWatcher(theme: theme, center: center, readsReduceMotion: {
            system.reads += 1
            return system.reduces
        })
    }

    @Test(arguments: [true, false])
    func itReadsTheSettingAtLaunch(reduces: Bool) {
        let theme = STTheme()
        let system = FakeSystem()
        system.reduces = reduces
        let watching = watcher(theme, system, NotificationCenter())
        #expect(theme.systemReduceMotion == reduces)
        #expect(theme.reduceMotion == reduces)
        #expect(system.reads == 1)
        _ = watching
    }

    @Test func itFollowsChangesWithoutTheWindow() {
        let theme = STTheme()
        let system = FakeSystem()
        let center = NotificationCenter()
        let watching = watcher(theme, system, center)

        system.reduces = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(theme.reduceMotion)

        system.reduces = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!theme.reduceMotion)
        _ = watching
    }

    @Test func otherNotificationsAreIgnored() {
        let theme = STTheme()
        let system = FakeSystem()
        let center = NotificationCenter()
        let watching = watcher(theme, system, center)
        system.reduces = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(!theme.systemReduceMotion)
        #expect(system.reads == 1)
        _ = watching
    }

    @Test func itNeverOverridesTheSwitch() {
        let theme = STTheme(motionMode: .reduced)
        let system = FakeSystem()
        let center = NotificationCenter()
        let watching = watcher(theme, system, center)
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(theme.motionMode == .reduced)
        #expect(theme.reduceMotion)
        _ = watching
    }

    @Test func itStopsListeningOnceGone() {
        let theme = STTheme()
        let system = FakeSystem()
        let center = NotificationCenter()
        var watching: SystemMotionWatcher? = watcher(theme, system, center)
        #expect(watching != nil)
        watching = nil
        system.reduces = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!theme.systemReduceMotion)
        #expect(system.reads == 1)
    }

    @Test func testsNeverReadTheRealMac() {
        // The harness builds the model without a watcher, so only the test decides.
        #expect(Harness().model.systemMotion == nil)
        #expect(!Harness().model.theme.systemReduceMotion)
        #expect(Harness(theme: STTheme(systemReduceMotion: true)).model.theme.systemReduceMotion)
    }
}

// MARK: - The main window

@MainActor
@Suite("Reduce animations: the main window", .serialized)
struct ReduceAnimationsWindowTests {
    @Test(arguments: [Route.settings, .tool(.crosshair), .home])
    func pagesChangeInPlace(route: Route) {
        let harness = reducedHarness()
        if route == .home { harness.model.navigate(to: .settings) }
        let hosted = window(harness)
        _ = hosted.capture()
        harness.model.navigate(to: route)
        let changed = hosted.capture()

        let fresh = reducedHarness()
        if route == .home { fresh.model.navigate(to: .settings) }
        fresh.model.navigate(to: route)
        #expect(sameImage(changed, window(fresh).capture()))
    }

    @Test func underFullMotionPagesSlide() {
        let harness = Harness()
        let hosted = window(harness)
        let before = hosted.capture()
        harness.model.navigate(to: .settings)
        let changed = hosted.captureNow()

        let fresh = reducedHarness()
        fresh.model.navigate(to: .settings)
        #expect(!sameImage(changed, before), "the change has begun")
        #expect(!sameImage(changed, window(fresh).capture()), "but it's still on its way")
    }

    @Test func goingBackAndForwardChangesInPlace() {
        let harness = reducedHarness()
        let hosted = window(harness)
        harness.model.navigate(to: .settings)
        _ = hosted.capture()
        harness.model.perform(.back)
        let back = hosted.capture()
        let fresh = reducedHarness()
        fresh.model.navigate(to: .settings)
        fresh.model.perform(.back)
        #expect(sameImage(back, window(fresh).capture()))
    }

    @Test func turningItOnTakesHoldAtOnce() {
        let harness = Harness()
        let hosted = window(harness)
        _ = hosted.capture()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        _ = hosted.capture()
        harness.model.navigate(to: .settings)
        let changed = hosted.capture()

        let fresh = reducedHarness()
        fresh.model.navigate(to: .settings)
        #expect(sameImage(changed, window(fresh).capture()), "the very next page change is in place")
    }

    @Test func turningItOffBringsTheSlideBack() {
        let harness = Harness()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = true
        let hosted = window(harness)
        _ = hosted.capture()
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = false
        let before = hosted.capture()
        harness.model.navigate(to: .settings)
        let changed = hosted.captureNow()

        let fresh = reducedHarness()
        fresh.model.navigate(to: .settings)
        #expect(!sameImage(changed, before))
        #expect(!sameImage(changed, window(fresh).capture()), "sliding again")
    }

    @Test func theIntroductionLeavesAtOnce() throws {
        let harness = reducedHarness()
        harness.model.beginPrologue(at: .openSTools)
        let hosted = window(harness)
        _ = hosted.capture()
        try #require(harness.model.prologue).next()
        #expect(harness.model.prologue == nil)
        let after = hosted.capture()
        #expect(sameImage(after, window(reducedHarness()).capture()))
    }

    @Test func underFullMotionTheIntroductionSlidesAway() throws {
        let harness = Harness()
        harness.model.beginPrologue(at: .openSTools)
        let hosted = window(harness)
        let before = hosted.capture()
        try #require(harness.model.prologue).next()
        let changed = hosted.captureNow()
        #expect(!sameImage(changed, before))
        #expect(!sameImage(changed, window(reducedHarness()).capture()))
    }

    @Test func theSidebarComesBackAtOnceForTheFinale() {
        let harness = reducedHarness()
        harness.model.beginPrologue(at: .keyRebinderTrial)
        let hosted = window(harness)
        _ = hosted.capture()
        harness.model.prologue?.next()
        #expect(harness.model.prologue?.showsSidebar == true)
        let after = hosted.capture()

        let fresh = reducedHarness()
        fresh.model.beginPrologue(at: .youreSet)
        #expect(sameImage(after, window(fresh).capture()))
    }

    /// The whole introduction in the real window, Continue on every step: every step is complete when it appears,
    /// so no key is ever spent completing something, the Finale switches the tried tools off with nothing pending,
    /// and it ends at Home.
    @Test(arguments: [false, true])
    func theWholeIntroductionRunsThroughWithNothingPending(byMacOS: Bool) throws {
        let harness = byMacOS ? Harness(theme: STTheme(systemReduceMotion: true)) : reducedHarness()
        harness.model.beginPrologue(at: .greeting)
        let hosted = window(harness)
        let prologue = try #require(harness.model.prologue)
        var seen: [PrologueStep] = []
        while let step = harness.model.prologue?.step, seen.count <= PrologueStep.count {
            seen.append(step)
            _ = hosted.capture()
            #expect(!prologue.animations.isRunning, "nothing for a key to complete on \(step)")
            switch step {
            case .crosshairTrial: harness.model.setTool(.crosshair, on: true)
            case .backdropTrial: harness.model.setTool(.windowBackdrop, on: true)
            case .youreSet:
                #expect(!harness.model.isOn(.crosshair) && !harness.model.isOn(.windowBackdrop), "off together, at once")
                #expect(!prologue.isFinaleRunning)
            default: break
            }
            prologue.next()
        }
        #expect(seen == PrologueStep.allCases)
        #expect(harness.model.prologue == nil)
        #expect(harness.model.route == .home)
        #expect(harness.store.load(AppState.self).prologueCompleted)
    }

    @Test func theWindowItselfOpensAndClosesWithoutAppKitsAnimation() {
        #expect(WindowConfigurator.animationBehavior(reducesMotion: true) == .none)
        #expect(WindowConfigurator.animationBehavior(reducesMotion: false) == .default)

        let theme = STTheme()
        let hosted = window(Harness(theme: theme))
        #expect(hosted.window.animationBehavior == .default)
        theme.motionMode = .reduced
        _ = hosted.capture()
        #expect(hosted.window.animationBehavior == .none, "live, without reopening the window")
        theme.motionMode = .full
        _ = hosted.capture()
        #expect(hosted.window.animationBehavior == .default)
        theme.systemReduceMotion = true
        _ = hosted.capture()
        #expect(hosted.window.animationBehavior == .none)
    }

    @Test func aWindowOpenedWhileReducedStartsWithoutAppKitsAnimation() {
        let hosted = window(reducedHarness())
        #expect(hosted.window.animationBehavior == .none)
    }
}

// MARK: - The hotkey confirmation

/// The panel goes to a display far outside every real one, so it never shows on a screen; it can be ordered in with or
/// without one connected.
@MainActor
@Suite("Reduce animations: the hotkey confirmation", .serialized)
struct ReduceAnimationsHUDTests {
    init() { _ = NSApplication.shared }

    // Fades here are a minute long, so "gone well inside the wait" can only mean no fade ran, however busy the main
    // actor is with other tests.

    @Test func itAppearsAtOnceAndLeavesRightAfterItsHold() async {
        let hud = HotkeyHUD(theme: STTheme(motionMode: .reduced), hold: .milliseconds(150),
                            fadeInDuration: 60, fadeOutDuration: 60)
        defer { hud.panel.hide() }
        hud.present("Crosshair on", sealed: true, on: offScreenDisplay)
        #expect(hud.isShowing)
        #expect(hud.panel.alphaValue == 1, "no fade in")
        #expect(await waitUntil(timeout: .seconds(20)) { !hud.isShowing }, "no minute-long fade out")
    }

    @Test func underFullMotionItFadesIn() async {
        let hud = HotkeyHUD(theme: STTheme(), hold: .milliseconds(100), fadeInDuration: 60, fadeOutDuration: 60)
        defer { hud.panel.hide() }
        hud.present("Crosshair on", sealed: true, on: offScreenDisplay)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(hud.panel.alphaValue < 1, "still fading in")
    }

    @Test func turningItOnWhileTheLineIsUpSkipsTheFadeOut() async {
        let theme = STTheme()
        let hud = HotkeyHUD(theme: theme, hold: .milliseconds(300), fadeInDuration: 0.01, fadeOutDuration: 60)
        defer { hud.panel.hide() }
        hud.present("Crosshair on", sealed: true, on: offScreenDisplay)
        theme.motionMode = .reduced
        #expect(await waitUntil(timeout: .seconds(20)) { !hud.isShowing })
    }

    @Test func aPressDuringAFadeOutComesBackAtOnceAndTheFadeNeverReturns() async {
        let theme = STTheme()
        let hud = HotkeyHUD(theme: theme, hold: .seconds(2), fadeInDuration: 0.01, fadeOutDuration: 0.5)
        defer { hud.panel.hide() }
        hud.present("Crosshair on", sealed: true, on: offScreenDisplay)
        // Into the full-motion fade-out, which would end at 2.5 s.
        try? await Task.sleep(for: .milliseconds(2_150))

        theme.motionMode = .reduced
        hud.present("Crosshair off", sealed: true, on: offScreenDisplay)
        #expect(hud.isShowing)
        #expect(hud.panel.alphaValue == 1, "the running fade stops; the line is simply there")

        // Past where the old fade would have ended, well before the new hold does.
        try? await Task.sleep(for: .milliseconds(650))
        #expect(hud.isShowing)
        #expect(hud.panel.alphaValue == 1, "the old fade didn't come back")
        #expect(await waitUntil(timeout: .seconds(10)) { !hud.isShowing })
    }

    @Test func aNewPressStillStartsItOver() async {
        let hud = HotkeyHUD(theme: STTheme(motionMode: .reduced), hold: .milliseconds(300), fadeInDuration: 1, fadeOutDuration: 1)
        defer { hud.panel.hide() }
        hud.present("Crosshair on", sealed: true, on: offScreenDisplay)
        try? await Task.sleep(for: .milliseconds(200))
        hud.present("Crosshair off", sealed: true, on: offScreenDisplay)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(hud.isShowing, "past the first press's hold, the second keeps it up")
        #expect(hud.panel.alphaValue == 1)
        #expect(await waitUntil { !hud.isShowing })
    }

    @Test func itsPanelNeverAnimatesInOrOut() {
        #expect(HotkeyHUD(theme: STTheme(motionMode: .reduced)).panel.animationBehavior == .none)
    }
}
