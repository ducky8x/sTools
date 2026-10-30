import AppKit
@testable import Crosshair
import Foundation
@testable import NBBOverlay
@testable import ScreenRecording
import STDesign
@testable import STPlatform
import Testing
@testable import sTools

// QA matrix (spec 9.2): "each tool alone and all together", "Minecraft windowed and full-screen", and the hotkey that
// switches tools together. The controllers and their windows are the app's own; see EverythingSupport.swift for what is
// faked around them.

@MainActor
@Suite("Every tool alone and all together", .serialized)
struct AllToolsTogetherTests {
    /// Waits until the tool's window is up: the NBB Overlay's comes with the first result, the others at once.
    private func waitForOverlays(_ harness: EverythingHarness, on display: DisplayInfo, topmost: Int, backdrops: Int) async -> Bool {
        await waitUntil(timeout: .seconds(10)) {
            let panels = harness.panels(on: display)
            return panels.filter { $0.role == .topmost }.count == topmost && panels.filter { $0.role == .backdrop }.count == backdrops
        }
    }

    // MARK: Each alone

    /// What each tool puts on the screen, and nothing else: the Crosshair, the NBB Overlay and the Timer Overlay one
    /// click-through window above everything, the backdrop one under Minecraft's, Screen Recording none.
    @Test(arguments: qaSwitchableTools)
    func eachToolAloneRaisesOnlyItsOwnWindow(tool: ToolID) async {
        let harness = EverythingHarness()
        let display = harness.display(1)
        #expect(harness.panels(on: display).isEmpty)

        // The switch a person flips; Screen Recording's would also start a recording, so it is armed the way its key arms it.
        if tool == .screenRecording { harness.model.setTool(tool, on: true) } else { harness.model.userSwitched(tool, on: true) }
        #expect(harness.model.isOn(tool))
        switch tool {
        case .crosshair, .timerOverlay, .nbbOverlay:
            #expect(await waitForOverlays(harness, on: display, topmost: 1, backdrops: 0))
        case .windowBackdrop:
            #expect(await waitForOverlays(harness, on: display, topmost: 0, backdrops: 1))
        case .screenRecording:
            #expect(await waitUntil(timeout: .seconds(10)) { harness.recording.sourcesAreReady })
            #expect(harness.panels(on: display).isEmpty, "a recording draws no window of its own")
        case .keyRebinder:
            Issue.record("the Key Rebinder has no switch")
        }
        for other in qaSwitchableTools where other != tool { #expect(!harness.model.isOn(other)) }

        harness.model.setTool(tool, on: false)
        #expect(await waitUntil { harness.panels(on: display).isEmpty })
        await harness.finish()
    }

    // MARK: All together

    @Test(arguments: [true, false])
    func allTheToolsTogetherKeepToTheirOwnLayers(reducedMotion: Bool) async throws {
        let harness = EverythingHarness(reducedMotion: reducedMotion)
        let display = harness.display(1)
        for tool in qaSwitchableTools {
            if tool == .screenRecording { harness.model.setTool(tool, on: true) } else { harness.model.userSwitched(tool, on: true) }
        }
        #expect(qaSwitchableTools.allSatisfy(harness.model.isOn))
        #expect(await waitForOverlays(harness, on: display, topmost: 3, backdrops: 1))
        #expect(await waitUntil(timeout: .seconds(10)) { harness.recording.sourcesAreReady })

        let panels = harness.panels(on: display)
        for panel in panels {
            #expect(!panel.canBecomeKey && !panel.canBecomeMain, "an overlay never takes focus from Minecraft")
            #expect(!panel.isKeyWindow && !panel.isMainWindow)
            #expect(!panel.hidesOnDeactivate && !panel.hasShadow)
        }
        let topmost = panels.filter { $0.role == .topmost }
        #expect(topmost.allSatisfy { $0.level == .screenSaver && $0.ignoresMouseEvents }, "above everything, and click-through")
        #expect(topmost.allSatisfy { $0.collectionBehavior.contains(.canJoinAllSpaces) && $0.collectionBehavior.contains(.fullScreenAuxiliary) })
        let backdrop = try #require(panels.first { $0.role == .backdrop })
        #expect(backdrop.level == .normal && !backdrop.ignoresMouseEvents, "an ordinary window level, swallowing clicks")
        #expect(backdrop.frame == display.frame, "edge to edge")
        #expect(topmost.allSatisfy { display.frame.contains($0.frame) }, "no overlay spills off Minecraft's display")

        // The Crosshair is the one on the display's center; the Timer's plate and the NBB Overlay's sit elsewhere.
        let centered = topmost.filter { $0.frame.contains(CGPoint(x: display.frame.midX, y: display.frame.midY)) }
        #expect(centered.count >= 1 && centered.contains { $0 === harness.crosshair.panel })

        // Every one of them is part of a recording, whose base layer asks for exactly these windows.
        let recorded = Set(OverlayPanel.visibleWindowNumbers())
        for panel in panels where !panel.isExcludedFromCapture { #expect(recorded.contains(UInt32(panel.windowNumber))) }

        // One by one they go, each taking only its own window.
        var remaining = panels.count
        for tool in qaSwitchableTools.reversed() {
            harness.model.setTool(tool, on: false)
            if tool != .screenRecording { remaining -= 1 }
            #expect(await waitUntil { harness.panels(on: display).count == remaining }, "after \(tool.title) went off")
        }
        #expect(remaining == 0)
        await harness.finish()
    }

    /// One key for the tools a key can toggle switches them all together and all off again, the Start-timer key adds the
    /// Timer Overlay's countdown to them, and each press is confirmed over the game once.
    @Test func hotkeysSwitchTheOverlaysTogether() async throws {
        let harness = EverythingHarness()
        let display = harness.display(1)
        harness.model.hotkeys.isEnabled = true
        let overlays = harness.model.hotkeys.add(
            combo: HotkeyCombo(keyCode: 96, modifiers: []),
            actions: [.toggle(.crosshair), .toggle(.nbbOverlay), .toggle(.windowBackdrop)])
        let timer = harness.model.hotkeys.add(combo: HotkeyCombo(keyCode: 97, modifiers: []), actions: [.startTimer])

        harness.registrar.onPress?(overlays)
        for tool in [ToolID.crosshair, .nbbOverlay, .windowBackdrop] { #expect(harness.model.isOn(tool)) }
        #expect(!harness.model.isOn(.timerOverlay))
        #expect(harness.hud.lines.count == 1)
        #expect(await waitForOverlays(harness, on: display, topmost: 2, backdrops: 1))

        harness.registrar.onPress?(timer)
        #expect(harness.model.isOn(.timerOverlay) && harness.timer.phase == .counting)
        #expect(harness.hud.lines.count == 1, "the countdown is its own confirmation")
        #expect(await waitForOverlays(harness, on: display, topmost: 3, backdrops: 1))

        harness.registrar.onPress?(overlays)
        for tool in [ToolID.crosshair, .nbbOverlay, .windowBackdrop] { #expect(!harness.model.isOn(tool)) }
        #expect(harness.model.isOn(.timerOverlay), "the timer's switch is its own")
        #expect(harness.hud.lines.count == 2)
        #expect(await waitForOverlays(harness, on: display, topmost: 1, backdrops: 0))
        await harness.finish()
        #expect(harness.panels(on: display).isEmpty, "quitting turns everything off")
    }

    // MARK: Windowed and full-screen

    /// Full-screen, the backdrop steps aside (Minecraft covers the display itself), and the overlays stay above the game.
    @Test func aFullScreenGameHidesTheBackdropAndKeepsTheOverlaysUp() async {
        let harness = EverythingHarness()
        let display = harness.display(1)
        for tool in [ToolID.crosshair, .timerOverlay, .nbbOverlay, .windowBackdrop] { harness.model.userSwitched(tool, on: true) }
        #expect(await waitForOverlays(harness, on: display, topmost: 3, backdrops: 1))

        harness.source.instances = [QADisplays.minecraft(on: display, fullScreen: true)]
        harness.model.minecraft.refresh()
        #expect(await waitForOverlays(harness, on: display, topmost: 3, backdrops: 0))

        harness.source.instances = [QADisplays.minecraft(on: display, fullScreen: false)]
        harness.model.minecraft.refresh()
        #expect(await waitForOverlays(harness, on: display, topmost: 3, backdrops: 1))
        await harness.finish()
    }

    /// Minecraft closed: the backdrop and the crosshair-style overlays that follow it fall back to the main display, or go.
    @Test func withoutMinecraftTheBackdropHidesAndTheCrosshairStaysOnTheMainDisplay() async {
        let harness = EverythingHarness()
        let display = harness.display(1)
        for tool in [ToolID.crosshair, .windowBackdrop] { harness.model.userSwitched(tool, on: true) }
        #expect(await waitForOverlays(harness, on: display, topmost: 1, backdrops: 1))

        harness.source.instances = []
        harness.model.minecraft.refresh()
        #expect(await waitForOverlays(harness, on: display, topmost: 1, backdrops: 0))
        await harness.finish()
    }
}
