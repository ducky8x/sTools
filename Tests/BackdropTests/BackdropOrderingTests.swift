import STPlatform
import Testing
@testable import Backdrop

@Suite("Backdrop ordering")
struct BackdropOrderingTests {
    private func window(number: UInt32 = 42, minimized: Bool = false, fullScreen: Bool = false) -> MinecraftWindow {
        MinecraftWindow(windowNumber: number, processID: 1, title: "Minecraft", frame: .zero, isMinimized: minimized, isFullScreen: fullScreen)
    }

    @Test func noMinecraftHidesEveryCoveredDisplay() {
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: [1, 2], minecraft: nil, minecraftDisplayID: nil, isMinecraftFocused: true, hideOnFullScreenScope: .thisDisplay)
        #expect(plans == [
            BackdropOrdering.DisplayPlan(displayID: 1, isVisible: false, orderBelowWindowNumber: nil),
            BackdropOrdering.DisplayPlan(displayID: 2, isVisible: false, orderBelowWindowNumber: nil),
        ])
    }

    @Test func minimizedMinecraftHidesEveryCoveredDisplay() {
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: [1], minecraft: window(minimized: true), minecraftDisplayID: 1, isMinecraftFocused: true, hideOnFullScreenScope: .thisDisplay)
        #expect(plans == [BackdropOrdering.DisplayPlan(displayID: 1, isVisible: false, orderBelowWindowNumber: nil)])
    }

    @Test func runningMinecraftShowsEveryCoveredDisplayOrderedBelowIt() {
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: [1, 2, 3], minecraft: window(number: 99), minecraftDisplayID: 1, isMinecraftFocused: true, hideOnFullScreenScope: .thisDisplay)
        #expect(plans == [1, 2, 3].map { BackdropOrdering.DisplayPlan(displayID: $0, isVisible: true, orderBelowWindowNumber: 99) })
    }

    @Test func fullScreenThisDisplayOnlyHidesMinecraftsOwnDisplay() {
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: [1, 2], minecraft: window(fullScreen: true), minecraftDisplayID: 1, isMinecraftFocused: true, hideOnFullScreenScope: .thisDisplay)
        #expect(plans.first { $0.displayID == 1 }?.isVisible == false)
        #expect(plans.first { $0.displayID == 2 }?.isVisible == true)
        #expect(plans.first { $0.displayID == 2 }?.orderBelowWindowNumber == 42)
    }

    @Test func fullScreenAllDisplaysHidesEveryCoveredDisplay() {
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: [1, 2], minecraft: window(fullScreen: true), minecraftDisplayID: 1, isMinecraftFocused: true, hideOnFullScreenScope: .allDisplays)
        #expect(plans.allSatisfy { !$0.isVisible && $0.orderBelowWindowNumber == nil })
    }

    @Test func fullScreenOnAnUncoveredDisplayDoesNotAffectCoveredOnes() {
        // Minecraft is full-screen on display 5, which isn't in the covered set at all.
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: [1, 2], minecraft: window(fullScreen: true), minecraftDisplayID: 5, isMinecraftFocused: true, hideOnFullScreenScope: .thisDisplay)
        #expect(plans.allSatisfy { $0.isVisible })
    }

    @Test func noCoveredDisplaysProducesNoPlans() {
        let plans = BackdropOrdering.plan(coveredDisplayIDs: [], minecraft: window(), minecraftDisplayID: 1, isMinecraftFocused: true, hideOnFullScreenScope: .thisDisplay)
        #expect(plans.isEmpty)
    }

    @Test func hidesWhenMinecraftNotFocusedOnlyAppliesWhenEnabled() {
        let stillShown = BackdropOrdering.plan(
            coveredDisplayIDs: [1], minecraft: window(), minecraftDisplayID: 1, isMinecraftFocused: false,
            hideOnFullScreenScope: .thisDisplay, hidesWhenMinecraftNotFocused: false)
        #expect(stillShown.first?.isVisible == true)

        let hidden = BackdropOrdering.plan(
            coveredDisplayIDs: [1], minecraft: window(), minecraftDisplayID: 1, isMinecraftFocused: false,
            hideOnFullScreenScope: .thisDisplay, hidesWhenMinecraftNotFocused: true)
        #expect(hidden == [BackdropOrdering.DisplayPlan(displayID: 1, isVisible: false, orderBelowWindowNumber: nil)])
    }

    @Test func hidesWhenMinecraftNotFocusedDoesNothingWhileFocused() {
        let plans = BackdropOrdering.plan(
            coveredDisplayIDs: [1], minecraft: window(), minecraftDisplayID: 1, isMinecraftFocused: true,
            hideOnFullScreenScope: .thisDisplay, hidesWhenMinecraftNotFocused: true)
        #expect(plans.first?.isVisible == true)
    }
}
