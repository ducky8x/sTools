import AppKit
@testable import Backdrop
import Foundation
@testable import NBBOverlay
import STDesign
@testable import STPlatform
import Testing
@testable import TimerOverlay
@testable import sTools

// QA matrix (spec 9.2): "Reduce animations on, and macOS's Reduce motion on with it off (the introduction, page changes,
// the hotkey confirmation, every overlay, then switching it back off)". ReducedAnimationsTests covers the window, the
// introduction, the pages and the confirmation; this covers every overlay in one app, by both routes, and the switch back.

/// How motion gets reduced: the app's switch (Settings ▸ Appearance ▸ Reduce animations), macOS's Reduce motion alone,
/// both, or neither.
enum ReduceRoute: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case appSwitch, macOS, both, neither

    var testDescription: String { rawValue }
    var reduces: Bool { self != .neither }
}

@MainActor
@Suite("Reduce animations through every overlay", .serialized)
struct ReduceMotionOverlaysTests {
    private func apply(_ route: ReduceRoute, to harness: EverythingHarness) {
        harness.model.appearanceBinding(\.reducesAnimations).wrappedValue = route == .appSwitch || route == .both
        harness.theme.systemReduceMotion = route == .macOS || route == .both
    }

    private func switchOverlaysOn(_ harness: EverythingHarness) async {
        for tool in [ToolID.crosshair, .timerOverlay, .nbbOverlay, .windowBackdrop] { harness.model.userSwitched(tool, on: true) }
        _ = await waitUntil { harness.nbb.isOverlayVisible && harness.presenter.isShowing }
    }

    /// The overlay that fades or crossfades does so only under full motion: the NBB Overlay's fade on reset and the
    /// backdrop's fill transition last their settings, or no time at all.
    @Test(arguments: ReduceRoute.allCases)
    func theFadesAndCrossfadesFollowTheRoute(route: ReduceRoute) async {
        let harness = EverythingHarness(reducedMotion: false)
        apply(route, to: harness)
        #expect(harness.theme.reduceMotion == route.reduces)
        #expect(harness.nbb.fadeDuration == (route.reduces ? 0 : harness.nbb.settings.fadeSeconds))
        #expect(harness.backdrop.fillTransitionSeconds == (route.reduces ? 0 : harness.backdrop.settings.fillTransitionSeconds))
        await harness.finish()
    }

    /// The Timer Overlay leaves at once when motion is reduced, and takes its exit animation (released by its backstop
    /// wake when the display never reports the end of it) when it isn't.
    @Test(arguments: ReduceRoute.allCases)
    func theTimerOverlayLeavesAtOnceOnlyWhenMotionIsReduced(route: ReduceRoute) async {
        let harness = EverythingHarness(reducedMotion: false)
        apply(route, to: harness)
        await switchOverlaysOn(harness)
        #expect(harness.presenter.isShowing && harness.timer.phase == .counting)

        harness.timer.cancel()
        if route.reduces {
            #expect(!harness.presenter.isShowing && harness.timer.phase == .idle, "gone in the same turn")
        } else {
            #expect(harness.presenter.isShowing && harness.timer.phase == .leaving, "its exit animation is playing")
            for wake in harness.timerScheduler.pending { wake.isCancelled = true; wake.action() }
            #expect(await waitUntil { !harness.presenter.isShowing && harness.timer.phase == .idle })
        }
        await harness.finish()
    }

    /// Switched back off, every overlay takes its motion again at once, without being switched off and on: the same
    /// controllers, the same windows.
    @Test(arguments: [ReduceRoute.appSwitch, .macOS, .both])
    func switchingMotionBackOnReachesTheOverlaysAlreadyUp(route: ReduceRoute) async {
        let harness = EverythingHarness(reducedMotion: false)
        apply(route, to: harness)
        await switchOverlaysOn(harness)
        let nbbPanel = harness.nbb.panel
        #expect(harness.nbb.fadeDuration == 0 && harness.backdrop.fillTransitionSeconds == 0)

        apply(.neither, to: harness)
        #expect(!harness.theme.reduceMotion)
        #expect(harness.nbb.fadeDuration == harness.nbb.settings.fadeSeconds)
        #expect(harness.backdrop.fillTransitionSeconds == harness.backdrop.settings.fillTransitionSeconds)
        #expect(harness.nbb.panel === nbbPanel && harness.nbb.isOverlayVisible, "nothing was rebuilt for it")

        // And back to reduced.
        apply(route, to: harness)
        #expect(harness.theme.reduceMotion && harness.nbb.fadeDuration == 0 && harness.backdrop.fillTransitionSeconds == 0)

        // The Timer Overlay's next exit follows the setting of that moment.
        harness.timer.cancel()
        #expect(!harness.presenter.isShowing)
        await harness.finish()
    }
}
