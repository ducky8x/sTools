import Testing
@testable import sTools

@Suite("NavigationHistory")
struct NavigationHistoryTests {
    @Test func startsOnHomeWithNowhereToGo() {
        let history = NavigationHistory()
        #expect(history.current == .home)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func pushMovesForwardAndEnablesBack() {
        var history = NavigationHistory()
        history.push(.tool(.crosshair))
        #expect(history.current == .tool(.crosshair))
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func pushingTheCurrentRouteChangesNothing() {
        var history = NavigationHistory()
        history.push(.settings)
        let before = history
        history.push(.settings)
        #expect(history == before)
    }

    @Test func backAndForwardWalkTheStack() {
        var history = NavigationHistory()
        history.push(.tool(.nbbOverlay))
        history.push(.settings)
        #expect(history.back() == .tool(.nbbOverlay))
        #expect(history.back() == .home)
        #expect(history.back() == nil)
        #expect(history.current == .home)
        #expect(history.forward() == .tool(.nbbOverlay))
        #expect(history.forward() == .settings)
        #expect(history.forward() == nil)
        #expect(history.current == .settings)
    }

    @Test func pushingAfterBackDropsTheForwardBranch() {
        var history = NavigationHistory()
        history.push(.tool(.windowBackdrop))
        history.push(.tool(.crosshair))
        history.back()
        history.push(.settings)
        #expect(!history.canGoForward)
        #expect(history.back() == .tool(.windowBackdrop))
        #expect(history.back() == .home)
        #expect(history.forward() == .tool(.windowBackdrop))
        #expect(history.forward() == .settings)
    }

    @Test func historyIsBounded() {
        var history = NavigationHistory(limit: 4)
        for tool in ToolID.allCases { history.push(.tool(tool)) }
        #expect(history.current == .tool(.keyRebinder))
        var steps = 0
        while history.back() != nil { steps += 1 }
        #expect(steps == 3)
    }
}

@Suite("Go menu")
struct GoCommandTests {
    @Test func menuListsHomeToolsSettingsThenBackAndForward() {
        #expect(GoCommand.menu == [
            .home, .tool(.nbbOverlay), .tool(.windowBackdrop), .tool(.crosshair),
            .tool(.screenRecording), .tool(.keyRebinder), .settings, .back, .forward,
        ])
    }

    @Test func destinationsMapToRoutes() {
        #expect(GoCommand.home.route == .home)
        #expect(GoCommand.settings.route == .settings)
        for tool in ToolID.allCases { #expect(GoCommand.tool(tool).route == .tool(tool)) }
        #expect(GoCommand.back.route == nil)
        #expect(GoCommand.forward.route == nil)
    }

    @Test func shortcutsFollowTheSpec() {
        #expect(GoCommand.home.shortcutKey == "0")
        #expect(GoCommand.tool(.nbbOverlay).shortcutKey == "1")
        #expect(GoCommand.tool(.windowBackdrop).shortcutKey == "2")
        #expect(GoCommand.tool(.crosshair).shortcutKey == "3")
        #expect(GoCommand.tool(.screenRecording).shortcutKey == "4")
        #expect(GoCommand.tool(.keyRebinder).shortcutKey == "5")
        #expect(GoCommand.settings.shortcutKey == ",")
        #expect(GoCommand.back.shortcutKey == "[")
        #expect(GoCommand.forward.shortcutKey == "]")
    }

    @Test func shortcutsAreUnique() {
        let keys = GoCommand.menu.map(\.shortcutKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test func titlesNameTheDestination() {
        #expect(GoCommand.home.title == "Home")
        #expect(GoCommand.tool(.crosshair).title == "Crosshair")
        #expect(GoCommand.settings.title == "Settings")
        #expect(GoCommand.back.title == "Back")
        #expect(GoCommand.forward.title == "Forward")
    }
}

@Suite("ToolID")
struct ToolIDTests {
    @Test func toolsAreNumberedOneToFiveInOrder() {
        #expect(ToolID.allCases.map(\.number) == [1, 2, 3, 4, 5])
        #expect(ToolID.allCases.map(\.title) == [
            "NBB Overlay", "Window Backdrop", "Crosshair", "Screen Recording", "Key Rebinder",
        ])
    }

    @Test func taglinesAreVerbatimFromRuleR13() {
        #expect(ToolID.nbbOverlay.tagline == "Ninjabrain Bot's answer, right over the game.")
        #expect(ToolID.windowBackdrop.tagline == "A clean stage behind Minecraft.")
        #expect(ToolID.crosshair.tagline == "The exact center, drawn your way.")
        #expect(ToolID.screenRecording.tagline == "Minecraft and everything else, on one canvas.")
        #expect(ToolID.keyRebinder.tagline == "Every rebind, right on its key.")
    }

    @Test func onlyKeyRebinderIsFreeOfAccessibilityAndSwitch() {
        for tool in ToolID.allCases where tool != .keyRebinder {
            #expect(tool.requiresAccessibility)
            #expect(tool.hasSwitch)
        }
        #expect(!ToolID.keyRebinder.requiresAccessibility)
        #expect(!ToolID.keyRebinder.hasSwitch)
    }

    @Test func sidebarNamesFitTheSidebar() {
        #expect(ToolID.allCases.map(\.sidebarTitle) == ["NBB Overlay", "Backdrop", "Crosshair", "Recording", "Key Rebinder"])
    }
}
