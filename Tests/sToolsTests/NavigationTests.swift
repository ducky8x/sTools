import STPlatform
import Testing
@testable import Prologue
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
            .home, .tool(.crosshair), .tool(.timerOverlay), .tool(.nbbOverlay), .tool(.screenRecording),
            .tool(.windowBackdrop), .tool(.keyRebinder), .settings, .back, .forward,
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
        #expect(GoCommand.tool(.crosshair).shortcutKey == "1")
        #expect(GoCommand.tool(.timerOverlay).shortcutKey == "2")
        #expect(GoCommand.tool(.nbbOverlay).shortcutKey == "3")
        #expect(GoCommand.tool(.screenRecording).shortcutKey == "4")
        #expect(GoCommand.tool(.windowBackdrop).shortcutKey == "5")
        #expect(GoCommand.tool(.keyRebinder).shortcutKey == "6")
        #expect(GoCommand.settings.shortcutKey == ",")
        #expect(GoCommand.back.shortcutKey == "[")
        #expect(GoCommand.forward.shortcutKey == "]")
    }

    @Test func shortcutsAreUnique() {
        let keys = GoCommand.menu.map(\.shortcutKey)
        #expect(Set(keys).count == keys.count)
    }

    /// Hotkeys fire with sTools in front, so the pages hold ⌃⌘: ⌘1–⌘5 belong to the key set.
    @Test func thePagesHoldControlAndCommand() {
        #expect(GoCommand.menu.map(\.shortcutDisplay)
            == ["⌃⌘0", "⌃⌘1", "⌃⌘2", "⌃⌘3", "⌃⌘4", "⌃⌘5", "⌃⌘6", "⌘,", "⌘[", "⌘]"])
    }

    /// No Go menu shortcut is a key any key set gives, so a press always reaches the one it means.
    @Test func noShortcutClashesWithAKeySet() {
        let keyCodes: [Character: UInt16] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
                                             ",": 43, "[": 33, "]": 30]
        let keySetCombos = Set(HotkeyKeySet.allCases.flatMap(\.combos))
        for command in GoCommand.menu {
            let keyCode = keyCodes[command.shortcutKey]
            #expect(keyCode != nil, "\(command)")
            let modifiers: HotkeyCombo.Modifiers = command.shortcutHoldsControl ? [.control, .command] : .command
            let combo = HotkeyCombo(keyCode: keyCode ?? 0, modifiers: modifiers)
            #expect(combo.displayString == command.shortcutDisplay)
            #expect(!keySetCombos.contains(combo), "\(command.shortcutDisplay)")
            #expect(combo.isValid, "\(command.shortcutDisplay) isn't a combination macOS keeps")
        }
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
    @Test func toolsAreNumberedOneToSixInOrder() {
        #expect(ToolID.allCases.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(ToolID.allCases.map(\.title) == [
            "Crosshair", "Timer Overlay", "NBB Overlay", "Screen Recording", "Window Backdrop", "Key Rebinder",
        ])
        #expect(ToolID.allCases == [.crosshair, .timerOverlay, .nbbOverlay, .screenRecording, .windowBackdrop, .keyRebinder])
    }

    @Test func taglinesAreVerbatimFromRuleR13() {
        #expect(ToolID.nbbOverlay.tagline == "Ninjabrain Bot's answer, right over the game.")
        #expect(ToolID.windowBackdrop.tagline == "A clean stage behind Minecraft.")
        #expect(ToolID.crosshair.tagline == "The exact center, drawn your way.")
        #expect(ToolID.timerOverlay.tagline == "Your Fire Resistance, counted down.")
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

    /// The stored names don't follow the order: tools saved as on at quit by a build with another sidebar order come
    /// back the same, and the hotkey names stay as written.
    @Test func storedNamesStayWhateverTheOrder() {
        let savedByAnEarlierOrder = ["nbbOverlay", "windowBackdrop", "crosshair", "timerOverlay", "screenRecording", "keyRebinder"]
        #expect(savedByAnEarlierOrder.compactMap(ToolID.init(rawValue:))
            == [.nbbOverlay, .windowBackdrop, .crosshair, .timerOverlay, .screenRecording, .keyRebinder])
        #expect(Set(ToolID.allCases.map(\.rawValue)) == Set(savedByAnEarlierOrder))
    }

    /// Lists of tools in the app's words follow the sidebar: Home's Accessibility warning and the Prologue's "Used by"
    /// for Accessibility name every tool that needs it (rule R10), in sidebar order.
    @Test func toolListsInWordsFollowTheSidebar() {
        let needAccessibility = ToolID.allCases.filter(\.requiresAccessibility).map(\.title)
        #expect(needAccessibility == ["Crosshair", "Timer Overlay", "NBB Overlay", "Screen Recording", "Window Backdrop"])
        #expect(HomePage.accessibilityWarning
            == "Accessibility isn't allowed yet, so Crosshair, Timer Overlay, NBB Overlay, Screen Recording and Window Backdrop stay off.")
        #expect(PermissionStepView.Copy.usedBy(.accessibility) == needAccessibility.joined(separator: ", "))
    }

    @Test func sidebarNamesFitTheSidebar() {
        #expect(ToolID.allCases.map(\.sidebarTitle) == ["Crosshair", "Timer Overlay", "NBB Overlay", "Recording", "Backdrop", "Key Rebinder"])
    }
}
