import AppKit
import KeyRebinder
import STDesign
@testable import STPlatform
import SwiftUI
import Testing
@testable import sTools

private let commandOne = HotkeyCombo(keyCode: 18, modifiers: .command)
private let commandQ = HotkeyCombo(keyCode: 12, modifiers: .command)
private let pad1 = HotkeyCombo(keyCode: 83, modifiers: [])

/// The sidebar's 236 pt and its hairline.
private let sidebarWidth: CGFloat = 237

/// A window that is never ordered in, holding `view` at `size`: SwiftUI lays it out and runs its tasks, and nothing
/// reaches the screen.
@MainActor
private final class Offscreen {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init<V: View>(_ view: V, size: CGSize) {
        _ = NSApplication.shared
        _ = STFont.register()
        host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle()
    }

    isolated deinit {
        window.contentView = nil
    }

    func settle() {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        host.layoutSubtreeIfNeeded()
    }
}

/// Home's page as it lays out in a window `size` big, at its natural height: what has to fit for Home not to scroll.
@MainActor
private func naturalHeight(_ harness: Harness, window size: CGSize) -> CGFloat {
    _ = STFont.register()
    let width = size.width - sidebarWidth
    let content = HomePageContent(model: harness.model, layout: HomeLayout(pageWidth: width))
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.stTheme, harness.model.theme)
        .environment(\.stSoundPlayer, STSoundPlayer.silent)
    return NSHostingView(rootView: content).fittingSize.height
}

// MARK: - The page

@MainActor
@Suite("Home dashboard: the page")
struct HomePageTests {
    @Test func theTaglineSaysWhatHomeHolds() {
        #expect(HomePage.tagline == "Your tools, their keys and what they need.")
    }

    /// The status visuals stand in a column beside the tools where there is room, and in a strip beside the title
    /// where there isn't: the default window and the minimum use the strip.
    @Test func theVisualsMoveBesideTheTitleInANarrowWindow() {
        for windowWidth in [CGFloat(680), 760] {
            #expect(!HomeLayout(pageWidth: windowWidth - sidebarWidth).showsLampColumn, "\(windowWidth)")
        }
        for windowWidth in [CGFloat(1000), 1440] {
            #expect(HomeLayout(pageWidth: windowWidth - sidebarWidth).showsLampColumn, "\(windowWidth)")
        }
    }

    /// Everything fits without scrolling from the 680 × 500 minimum up at the default text size, in the states that
    /// take the most room: Accessibility missing, hotkeys off (their line shows), two Minecrafts open, and Karabiner
    /// either missing or ready with many long profile names, each with a key, and a key for Next profile.
    @Test(arguments: [CGSize(width: 680, height: 500), CGSize(width: 760, height: 560), CGSize(width: 1000, height: 700),
                      CGSize(width: 1440, height: 900)])
    func everythingFitsTheWindow(size: CGSize) async {
        let crowded = (1...12).map { "Profile with a rather long name \($0)" }
        for profiles in [nil, crowded] {
            let harness = Harness(accessibility: .denied, instances: [fakeInstance(pid: 1), fakeInstance(pid: 2, launched: 2)],
                                  withKeyRebinder: true, karabiner: profiles.map { HarnessKarabiner(profiles: $0) })
            await harness.model.refreshHomeStatuses()
            // ⌃⌥A to ⌃⌥L, one for each profile.
            let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37]
            for (name, letter) in zip(profiles ?? [], letters) {
                harness.model.hotkeys.setProfileHotkey(HotkeyCombo(keyCode: letter, modifiers: [.control, .option]), for: name)
            }
            if profiles != nil { ToolHotkey.set(pad1, for: .profile(.next), in: harness.model.hotkeys) }
            #expect(!harness.model.hotkeys.isEnabled)
            let height = naturalHeight(harness, window: size)
            #expect(height <= size.height, "\(Int(size.width)) × \(Int(size.height)): \(height) pt")
        }
    }

    /// At the largest text size Home may scroll, but it still lays out: nothing collapses.
    @Test func atTheLargestTextSizeItStillLaysOut() {
        let harness = Harness()
        harness.model.theme.textScale = 1.3
        #expect(naturalHeight(harness, window: CGSize(width: 680, height: 500)) > 500)
    }

    /// Home checks Karabiner-Elements and Ninjabrain Bot as it appears and as sTools comes to the front, and at no other
    /// time: nothing polls, and nothing runs while another page shows.
    @Test func homeChecksOnAppearAndActivationAndNeverPolls() async throws {
        let cli = HarnessKarabiner(profiles: ["Default profile", "Speedrun"])
        let harness = Harness(karabiner: cli)
        let notifications = NotificationCenter()
        harness.model.appNotifications = notifications
        final class Counter { var pings = 0 }
        let counter = Counter()
        harness.model.pingNinjabrainBot = {
            counter.pings += 1
            return true
        }
        let window = Offscreen(RootView(model: harness.model), size: CGSize(width: 760, height: 560))
        #expect(await waitUntil { cli.count("--list-profile-names") == 1 && counter.pings == 1 })
        #expect(harness.model.ninjabrainAnswers == true)
        try await Task.sleep(for: .milliseconds(600))
        window.settle()
        #expect(cli.count("--list-profile-names") == 1 && counter.pings == 1, "no polling")

        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await waitUntil { cli.count("--list-profile-names") == 2 && counter.pings == 2 })

        harness.model.navigate(to: .settings)
        window.settle()
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        window.settle()
        #expect(cli.count("--list-profile-names") == 2 && counter.pings == 2, "Home isn't showing")
        #expect(!cli.calls.contains { $0.first == "--list-connected-devices" }, "Home asks for no devices")
    }

    /// While the NBB Overlay runs, Home reads its link from the overlay and pings nothing.
    @Test func aRunningOverlaySaysWhetherNinjabrainBotIsLinked() async {
        let harness = Harness(usesRealControllers: true)
        final class Counter { var pings = 0 }
        let counter = Counter()
        harness.model.pingNinjabrainBot = {
            counter.pings += 1
            return true
        }
        harness.model.setTool(.nbbOverlay, on: true)
        await harness.model.refreshHomeStatuses()
        #expect(counter.pings == 0)
        #expect(harness.model.homeLamp(.ninjabrainBot).state == .dim, "the harness's Ninjabrain Bot never answers")
        harness.model.setTool(.nbbOverlay, on: false)
        await harness.model.refreshHomeStatuses()
        #expect(counter.pings == 1)
        #expect(harness.model.homeLamp(.ninjabrainBot).state == .lit)
    }

    /// While hotkeys are off one quiet line says so, with Turn On; it goes once they're on.
    @Test func aQuietLineSaysHotkeysAreOff() {
        #expect(HomeHotkeysOffLine.text == "Hotkeys are off. Turn them on to use these keys.")
        let harness = Harness()
        #expect(!harness.model.hotkeys.isEnabled)
        let off = naturalHeight(harness, window: CGSize(width: 760, height: 560))
        HomeHotkeysOffLine(model: harness.model).turnOn()
        #expect(harness.model.hotkeys.isEnabled)
        #expect(naturalHeight(harness, window: CGSize(width: 760, height: 560)) < off)
    }
}

// MARK: - The tools

@MainActor
@Suite("Home dashboard: tool tiles")
struct HomeToolTileTests {
    /// Two columns and three rows in sidebar order, read row by row.
    @Test func theTilesFollowTheSidebarRowByRow() {
        #expect(HomeToolGrid.rows == [[.crosshair, .timerOverlay], [.nbbOverlay, .screenRecording], [.windowBackdrop, .keyRebinder]])
    }

    /// A tile's switch takes the sidebar's path: Timer Overlay's starts a countdown, as its switch does everywhere.
    @Test func theSwitchTakesTheSidebarsPath() {
        let harness = Harness()
        let tile = HomeToolTile(model: harness.model, tool: .timerOverlay)
        tile.setSwitch(true)
        #expect(harness.model.isOn(.timerOverlay))
        #expect(harness.timer.phase == .counting)
        tile.setSwitch(false)
        #expect(!harness.model.isOn(.timerOverlay))
    }

    @Test func clickingATileOpensItsPage() {
        let harness = Harness()
        for tool in ToolID.allCases {
            HomeToolTile(model: harness.model, tool: tool).open()
            #expect(harness.model.route == .tool(tool))
        }
    }

    /// Without Accessibility a tile that needs it offers Allow… where its switch was, and asks for it.
    @Test func withoutAccessibilityATileOffersAllow() async {
        let harness = Harness(accessibility: .denied)
        let crosshair = HomeToolTile(model: harness.model, tool: .crosshair)
        #expect(crosshair.offersAllow)
        #expect(!HomeToolTile(model: harness.model, tool: .keyRebinder).offersAllow)
        #expect(HomeToolTile.allowHelp(.crosshair) == "Crosshair needs Accessibility to find the Minecraft window.")
        await crosshair.allowAccessibility()
        #expect(harness.prober.requested == [.accessibility])
        #expect(!HomeToolTile(model: Harness(accessibility: .granted).model, tool: .crosshair).offersAllow)
    }

    /// The key cap sets the tool's own hotkey the way the tool page's Hotkey row does, with the same refusals and the
    /// same words for a key that doesn't work. Hotkeys can be off meanwhile.
    @Test func theKeyCapSetsTheToolsOwnKey() throws {
        let harness = Harness()
        let hotkeys = harness.model.hotkeys
        #expect(!hotkeys.isEnabled)
        let tile = HomeToolTile(model: harness.model, tool: .crosshair)
        let key = try #require(tile.keyBinding)
        #expect(key.wrappedValue == nil)
        key.wrappedValue = commandOne.asSTShortcut
        #expect(ToolHotkey.own(for: .toggle(.crosshair), in: hotkeys.bindings)?.combo == commandOne)

        let row = try #require(ToolHotkeyRow(model: harness.model, tool: .nbbOverlay))
        let nbb = HomeToolTile(model: harness.model, tool: .nbbOverlay)
        #expect(nbb.refusal(for: commandOne.asSTShortcut) == ToolHotkey.refusal(for: commandOne, action: row.action, in: hotkeys))
        #expect(nbb.refusal(for: commandOne.asSTShortcut) == "Already used by another hotkey")
        #expect(nbb.refusal(for: commandQ.asSTShortcut) == "Reserved: Quit")
        #expect(nbb.refusal(for: pad1.asSTShortcut) == nil)

        key.wrappedValue = nil
        #expect(ToolHotkey.own(for: .toggle(.crosshair), in: hotkeys.bindings) == nil)
        #expect(HomeToolTile(model: harness.model, tool: .keyRebinder).keyBinding == nil, "the Key Rebinder's keys are on its keys")
    }

    /// A key another hotkey has is drawn red, and says why in the tool page's words.
    @Test func aKeyThatDoesntWorkSaysSoInThePagesWords() throws {
        let harness = Harness()
        harness.model.hotkeys.isEnabled = true
        let hotkeys = harness.model.hotkeys
        ToolHotkey.set(pad1, for: .toggle(.crosshair), in: hotkeys)
        ToolHotkey.set(pad1, for: .toggle(.nbbOverlay), in: hotkeys)
        let tile = HomeToolTile(model: harness.model, tool: .nbbOverlay)
        let row = try #require(ToolHotkeyRow(model: harness.model, tool: .nbbOverlay))
        #expect(tile.keyProblem != nil)
        #expect(tile.keyProblem == row.problemNote)
        #expect(HomeToolTile(model: harness.model, tool: .crosshair).keyProblem == nil)
    }

    /// The status line says what the tool is doing, and while the key cap listens it says how to finish.
    @Test func theStatusLineFollowsTheKeyCap() {
        let harness = Harness()
        let tile = HomeToolTile(model: harness.model, tool: .crosshair)
        #expect(tile.statusLine(.idle) == HomeToolTile.StatusLine(text: "OFF", tone: .quiet))
        #expect(tile.statusLine(.listening) == HomeToolTile.StatusLine(text: "Esc cancels, Delete clears", tone: .accent))
        #expect(tile.statusLine(.refused("Reserved: Quit")) == HomeToolTile.StatusLine(text: "Reserved: Quit", tone: .danger))
        harness.model.setTool(.crosshair, on: true)
        #expect(tile.statusLine(.idle) == HomeToolTile.StatusLine(text: "ON", tone: .accent))
    }

    /// VoiceOver reads the tile's tool and status, and the key as words.
    @Test func voiceOverReadsTheToolStatusAndKey() {
        let harness = Harness()
        ToolHotkey.set(commandOne, for: .toggle(.crosshair), in: harness.model.hotkeys)
        let tile = HomeToolTile(model: harness.model, tool: .crosshair)
        #expect(tile.spokenTitle == "1, Crosshair")
        #expect(tile.spokenStatus == "Off")
        #expect(tile.spokenKey == "Command 1")
        #expect(tile.keyLabel == "Crosshair hotkey")
    }
}

// MARK: - The Key Rebinder

@MainActor
@Suite("Home dashboard: Key Rebinder profiles", .serialized)
struct HomeKeyRebinderTileTests {
    /// One click switches Karabiner-Elements to a profile, through the profile hotkeys' own switch
    /// (`switchProfile(for:)`), and leaves no parsed `karabiner.json` behind. The tile reads the profiles through the Key
    /// Rebinder's one read (`profiles`, `refreshProfiles()`).
    @Test func oneClickSwitchesTheProfile() async throws {
        let cli = HarnessKarabiner(profiles: ["Default profile", "Speedrun", "Typing"])
        let harness = Harness(karabiner: cli)
        let keyRebinder = try #require(harness.model.keyRebinder)
        await harness.model.refreshHomeStatuses()
        let tile = HomeKeyRebinderTile(model: harness.model)
        #expect(tile.profiles == keyRebinder.profiles.names)
        #expect(tile.profiles == ["Default profile", "Speedrun", "Typing"])
        #expect(tile.current == "Default profile")
        #expect(keyRebinder.config == nil, "Home's check keeps no file")

        #expect(await tile.choose("Speedrun") == .switched(to: "Speedrun"))
        #expect(cli.selects == ["Speedrun"])
        #expect(tile.current == "Speedrun")
        #expect(keyRebinder.config == nil, "nothing is loaded with the page closed")
        #expect(harness.model.homeLamp(.karabiner).state == .lit)

        // A profile Karabiner-Elements doesn't have doesn't switch, and the tile says why in the confirmation's words.
        let gone = await tile.choose("Gone")
        #expect(gone == .missing("Gone"))
        #expect(tile.current == "Speedrun")
        #expect(HomeKeyRebinderTile.failure(gone) == "No profile named \u{201C}Gone\u{201D}")
        #expect(HomeKeyRebinderTile.failure(.switched(to: "Typing")) == nil)
        #expect(HomeKeyRebinderTile.failure(.alreadyCurrent("Typing")) == nil)
    }

    /// Until Karabiner-Elements is ready the tile says why in a line, in the Prologue's words, and offers no profiles.
    @Test func withoutKarabinerTheTileSaysWhy() async throws {
        let harness = Harness(withKeyRebinder: true)
        await harness.model.refreshHomeStatuses()
        let tile = HomeKeyRebinderTile(model: harness.model)
        #expect(tile.profiles.isEmpty)
        #expect(tile.setupNote == "Karabiner-Elements isn\u{2019}t installed.")
        #expect(tile.setupHelp == KarabinerRequirement.notInstalled.fixText)
        #expect(HomeKeyRebinderTile(model: Harness(withKeyRebinder: true).model).setupNote == "Looking for Karabiner-Elements\u{2026}")
    }

    /// Names cut to fit their chip stay apart. One that shares a long beginning with another profile's starts from where
    /// the two differ; any other keeps its end in view. The help tag and VoiceOver have the whole name.
    @Test func cutNamesStayApart() {
        let room = HomeProfileChip.room
        let numbered = (1...3).map { "Practice profile number \($0) with a long name" }
        let shown = numbered.map { HomeProfileChip.shownName(of: $0, among: numbered) }
        #expect(Set(shown.map { String($0.prefix(room)) }).count == numbered.count, "\(shown)")
        #expect(shown.allSatisfy { $0.hasPrefix("\u{2026}") })
        #expect(shown[0].contains("number 1"))

        let speedruns = ["Minecraft speedrun practice", "Minecraft speedrun ranked"]
        let cut = speedruns.map { HomeProfileChip.shownName(of: $0, among: speedruns) }
        #expect(cut[0] != cut[1] && String(cut[0].prefix(room)) != String(cut[1].prefix(room)), "\(cut)")

        // A name that fits, or shares no long beginning, is shown whole and cut in the middle only if it must be.
        let plain = ["Default profile", "Speedrun", "A long name that nothing else starts like"]
        #expect(plain.map { HomeProfileChip.shownName(of: $0, among: plain) } == plain)
        #expect(HomeProfileChip.truncation(of: "\u{2026}number 1 with a long name") == .tail)
        #expect(HomeProfileChip.truncation(of: "Default profile") == .middle)

        // In a row too narrow for that, the cut starts at the word where the names differ, without the one before it.
        let tens = (1...12).map { "Practice profile number \($0) with a long name" }
        let tight = tens.map { HomeProfileChip.shownName(of: $0, among: tens, wordsBefore: 0) }
        #expect(tight[0] == "\u{2026}1 with a long name")
        #expect(tight[9] == "\u{2026}10 with a long name")
        #expect(Set(tight.map { String($0.prefix(4)) }).count == tens.count, "\(tight)")
        #expect(plain.map { HomeProfileChip.shownName(of: $0, among: plain, wordsBefore: 0) } == plain)
    }

    /// Many long profile names make the tile no taller than its neighbor: they truncate, in one row that scrolls.
    @Test func manyLongProfilesDontBreakTheTile() async throws {
        let profiles = (1...14).map { "A profile with a very long name, number \($0)" }
        let harness = Harness(karabiner: HarnessKarabiner(profiles: profiles))
        await harness.model.refreshHomeStatuses()
        func height<V: View>(_ view: V) -> CGFloat {
            NSHostingView(rootView: view.frame(width: 220).fixedSize(horizontal: false, vertical: true)
                .environment(\.stTheme, harness.model.theme)).fittingSize.height
        }
        for (index, name) in profiles.enumerated() {
            harness.model.hotkeys.setProfileHotkey(HotkeyCombo(keyCode: 122, modifiers: index.isMultiple(of: 2) ? .control : .option),
                                                   for: name)
        }
        ToolHotkey.set(pad1, for: .profile(.next), in: harness.model.hotkeys)
        let rebinder = height(HomeKeyRebinderTile(model: harness.model))
        let backdrop = height(HomeToolTile(model: harness.model, tool: .windowBackdrop))
        #expect(rebinder <= backdrop + 4, "\(rebinder) pt beside \(backdrop) pt")
        #expect(HomeProfileChip.widest < 220)
    }

    /// The tile's key cap, bottom left like every tile's, is Next profile's own key: set, changed and cleared in place
    /// with the tool pages' refusals and words, whether hotkeys are on or off.
    @Test func theKeyCapSetsNextProfilesKey() async throws {
        let harness = Harness(karabiner: HarnessKarabiner(profiles: ["Default profile", "Speedrun"]))
        await harness.model.refreshHomeStatuses()
        let hotkeys = harness.model.hotkeys
        ToolHotkey.set(commandOne, for: .toggle(.crosshair), in: hotkeys)
        let tile = HomeKeyRebinderTile(model: harness.model)
        #expect(tile.showsNextKey)
        #expect(tile.nextKey.wrappedValue == nil)
        #expect(tile.nextKeyLabel == "Next profile hotkey")

        tile.nextKey.wrappedValue = pad1.asSTShortcut
        let own = try #require(ToolHotkey.own(for: .profile(.next), in: hotkeys.bindings))
        #expect(own.combo == pad1)
        #expect(tile.nextKey.wrappedValue == pad1.asSTShortcut)
        #expect(tile.nextSpokenKey == HotkeyWording.spokenName(for: pad1))

        #expect(tile.nextKeyRefusal(for: commandOne.asSTShortcut) == "Already used by another hotkey")
        #expect(tile.nextKeyRefusal(for: commandQ.asSTShortcut) == "Reserved: Quit")
        #expect(tile.nextKeyRefusal(for: pad1.asSTShortcut) == nil, "its own key")
        #expect(tile.nextKeyRefusal(for: commandOne.asSTShortcut)
            == ToolHotkey.refusal(for: commandOne, action: .profile(.next), in: hotkeys))

        tile.nextKey.wrappedValue = nil
        #expect(ToolHotkey.own(for: .profile(.next), in: hotkeys.bindings) == nil)
        #expect(hotkeys.bindings.count == 1, "the Crosshair's key stays")
    }

    /// Until a profile can be switched to there's nothing for Next profile to do, so its cap waits, unless it already
    /// has a key: a key that's set stays in view.
    @Test func theNextProfileCapWaitsForKarabinerUnlessItHasAKey() async {
        let harness = Harness(withKeyRebinder: true)
        await harness.model.refreshHomeStatuses()
        let tile = HomeKeyRebinderTile(model: harness.model)
        #expect(!tile.showsNextKey)
        ToolHotkey.set(pad1, for: .profile(.next), in: harness.model.hotkeys)
        #expect(tile.showsNextKey)
        #expect(!HomeKeyRebinderTile(model: Harness().model).showsNextKey, "no Key Rebinder, no cap")
    }

    /// Each chip shows its profile's own key, and its menu's Set Key… and Remove Key set it through the profile's own
    /// hotkey, refusing what the tool pages refuse. Other hotkeys that switch to it, and the list's order, stay.
    @Test func aChipShowsAndSetsItsProfilesKey() async throws {
        let harness = Harness(karabiner: HarnessKarabiner(profiles: ["Default profile", "Speedrun", "Typing"]))
        await harness.model.refreshHomeStatuses()
        let hotkeys = harness.model.hotkeys
        ToolHotkey.set(commandOne, for: .toggle(.crosshair), in: hotkeys)
        let shared = hotkeys.add(combo: HotkeyCombo(keyCode: 97, modifiers: []),
                                 actions: [.toggle(.crosshair), .profile(.select("Speedrun"))])
        let tile = HomeKeyRebinderTile(model: harness.model)
        #expect(tile.profileKey(for: "Speedrun") == nil, "a shared hotkey isn't the profile's own key")

        let controlF6 = HotkeyCombo(keyCode: 97, modifiers: .control)
        tile.setKey(controlF6.asSTShortcut, for: "Speedrun")
        #expect(hotkeys.profileHotkey(for: "Speedrun")?.combo == controlF6)
        #expect(tile.profileKey(for: "Speedrun")?.combo == controlF6)
        #expect(tile.profileKey(for: "Typing") == nil)
        #expect(hotkeys.bindings.first?.actions == [.toggle(.crosshair)], "the list's order stays")
        #expect(hotkeys.bindings.contains { $0.id == shared })

        #expect(tile.refusal(for: commandOne.asSTShortcut, profile: "Typing") == "Already used by another hotkey")
        #expect(tile.refusal(for: controlF6.asSTShortcut, profile: "Typing") == "Already used by another hotkey")
        #expect(tile.refusal(for: controlF6.asSTShortcut, profile: "Speedrun") == nil, "its own key")
        #expect(tile.refusal(for: commandQ.asSTShortcut, profile: "Typing")
            == ToolHotkey.refusal(for: commandQ, action: .profile(.select("Typing")), in: hotkeys))

        tile.setKey(nil, for: "Speedrun")
        #expect(hotkeys.profileHotkey(for: "Speedrun") == nil)
        #expect(hotkeys.hotkeys(switchingTo: "Speedrun").map(\.id) == [shared], "the shared hotkey stays")
    }

    /// A profile's key that doesn't work says so in the tool pages' words, in the chip's help and to VoiceOver.
    @Test func aProfileKeyThatDoesntWorkSaysSo() async throws {
        let harness = Harness(karabiner: HarnessKarabiner(profiles: ["Default profile", "Speedrun"]))
        await harness.model.refreshHomeStatuses()
        let hotkeys = harness.model.hotkeys
        hotkeys.isEnabled = true
        ToolHotkey.set(pad1, for: .toggle(.crosshair), in: hotkeys)
        hotkeys.setProfileHotkey(pad1, for: "Speedrun")
        let tile = HomeKeyRebinderTile(model: harness.model)
        let own = try #require(hotkeys.profileHotkey(for: "Speedrun"))
        let problem = try #require(tile.keyProblem(for: "Speedrun"))
        #expect(problem == HotkeyWording.statusNote(hotkeys.status(of: own.id), combo: pad1, inList: false))
        #expect(tile.chipHelp(for: "Speedrun").contains(problem))
        #expect(tile.spokenKey(for: "Speedrun").contains(problem))
        #expect(tile.keyProblem(for: "Default profile") == nil)
    }

    /// The help tag and VoiceOver have the whole name, the key and how to change it; without a key, how to add one.
    @Test func aChipSaysItsKeyAndHowToSetIt() async throws {
        let harness = Harness(karabiner: HarnessKarabiner(profiles: ["Default profile", "Speedrun"]))
        await harness.model.refreshHomeStatuses()
        let tile = HomeKeyRebinderTile(model: harness.model)
        #expect(tile.chipHelp(for: "Speedrun") == "Speedrun. Control-click to give it a key.")
        #expect(tile.spokenKey(for: "Speedrun") == "No key")
        harness.model.hotkeys.setProfileHotkey(commandOne, for: "Speedrun")
        #expect(tile.chipHelp(for: "Speedrun").hasPrefix("Speedrun. \u{2318}1 switches to it."))
        #expect(tile.chipHelp(for: "Speedrun").hasSuffix("Control-click to change its key."))
        #expect(tile.spokenKey(for: "Speedrun") == "Command 1")
    }

    /// While the key cap or a chip listens, the line under the name says how to finish, and why a key was refused; a
    /// profile that didn't switch says why; otherwise it's the tool's status.
    @Test func theStatusLineFollowsTheKeyBeingSet() async {
        let harness = Harness(karabiner: HarnessKarabiner())
        await harness.model.refreshHomeStatuses()
        let tile = HomeKeyRebinderTile(model: harness.model)
        typealias Line = HomeToolTile.StatusLine
        #expect(tile.statusLine(.idle) == Line(text: "ALWAYS AVAILABLE", tone: .quiet))
        #expect(tile.statusLine(.listening) == Line(text: "Esc cancels, Delete clears", tone: .accent))
        #expect(tile.statusLine(.refused("Reserved: Quit")) == Line(text: "Reserved: Quit", tone: .danger))
        let gone = "No profile named \u{201C}Gone\u{201D}"
        #expect(tile.statusLine(.idle, switchError: gone) == Line(text: gone, tone: .danger))
        #expect(tile.statusLine(.listening, switchError: gone) == Line(text: "Esc cancels, Delete clears", tone: .accent))
    }
}

// MARK: - The status visuals

@MainActor
@Suite("Home dashboard: status visuals")
struct HomeLampTests {
    @Test func minecraftLightsWhileItRunsAndUsesHomesSentences() {
        let displays = [harnessDisplay]
        let missing = HomeLamps.minecraft(active: nil, others: [], conflict: .none, displays: displays, accessibilityGranted: true)
        #expect(missing == HomeLamp(state: .dim, sentence: "Minecraft isn\u{2019}t running."))
        let running = fakeInstance()
        #expect(HomeLamps.minecraft(active: running, others: [], conflict: .none, displays: displays, accessibilityGranted: true)
            == HomeLamp(state: .lit, sentence: "Minecraft 1.16.1 is open on Off screen."))
        let blind = HomeLamps.minecraft(active: nil, others: [], conflict: .none, displays: displays, accessibilityGranted: false)
        #expect(blind.state == .problem)
        #expect(blind.sentence == "sTools can\u{2019}t look for Minecraft until Accessibility is allowed.")
        let second = fakeInstance(pid: 2, version: "1.16.1", launched: 2)
        let two = HomeLamps.minecraft(active: running, others: [second], conflict: .multiple(count: 2, followingVersion: "1.16.1"),
                                      displays: displays, accessibilityGranted: true)
        #expect(two.state == .lit)
        #expect(two.count == 2)
        #expect(two.sentence == MinecraftStatusText.make(active: running, others: [second],
                                                         conflict: .multiple(count: 2, followingVersion: "1.16.1"),
                                                         displays: displays, accessibilityGranted: true))
    }

    @Test func ninjabrainBotLightsWhenLinked() {
        #expect(HomeLamps.ninjabrainBot(overlayIsOn: true, reachable: true, readsWindow: false, answers: nil)
            == HomeLamp(state: .lit, sentence: "Ninjabrain Bot is linked through its API."))
        #expect(HomeLamps.ninjabrainBot(overlayIsOn: true, reachable: true, readsWindow: true, answers: nil)
            == HomeLamp(state: .lit, sentence: "Ninjabrain Bot is linked through its window."))
        #expect(HomeLamps.ninjabrainBot(overlayIsOn: true, reachable: false, readsWindow: false, answers: true)
            == HomeLamp(state: .dim, sentence: PrologueCopy.ninjabrainSilent))
        #expect(HomeLamps.ninjabrainBot(overlayIsOn: false, reachable: false, readsWindow: false, answers: true)
            == HomeLamp(state: .lit, sentence: PrologueCopy.ninjabrainAnswers))
        #expect(HomeLamps.ninjabrainBot(overlayIsOn: false, reachable: false, readsWindow: false, answers: false)
            == HomeLamp(state: .dim, sentence: PrologueCopy.ninjabrainSilent))
        #expect(HomeLamps.ninjabrainBot(overlayIsOn: false, reachable: false, readsWindow: false, answers: nil)
            == HomeLamp(state: .dim, sentence: "Looking for Ninjabrain Bot\u{2026}"))
    }

    /// Karabiner-Elements lights when ready, stays dim while it isn't installed, and turns red for a real problem, each
    /// with the Key Rebinder's own sentence.
    @Test func karabinerLightsWhenReadyAndRedOnlyForAProblem() {
        #expect(HomeLamps.karabiner(.ready, profile: "Speedrun")
            == HomeLamp(state: .lit, sentence: "Karabiner-Elements is ready, using the Speedrun profile."))
        #expect(HomeLamps.karabiner(.ready, profile: nil) == HomeLamp(state: .lit, sentence: "Karabiner-Elements is ready."))
        #expect(HomeLamps.karabiner(.notInstalled, profile: nil)
            == HomeLamp(state: .dim, sentence: KarabinerRequirement.notInstalled.fixText))
        for problem in [KarabinerRequirement.notRunning, .versionTooOld(found: "15.3.0"), .configUnreadable] {
            #expect(HomeLamps.karabiner(problem, profile: nil) == HomeLamp(state: .problem, sentence: problem.fixText))
        }
        #expect(HomeLamps.karabiner(nil, profile: nil) == HomeLamp(state: .dim, sentence: "Looking for Karabiner-Elements\u{2026}"))
    }

    /// Clicking Karabiner-Elements or Ninjabrain Bot opens the page where it's fixed; Minecraft opens nothing.
    @Test func aVisualOpensThePageWhereItsFixed() {
        #expect(HomeLampKind.karabiner.destination == .tool(.keyRebinder))
        #expect(HomeLampKind.ninjabrainBot.destination == .tool(.nbbOverlay))
        #expect(HomeLampKind.minecraft.destination == nil)
        #expect(HomeLampKind.allCases.map(\.name) == ["Minecraft", "Ninjabrain Bot", "Karabiner"])
        #expect(HomeLampKind.allCases.map(\.spokenName) == ["Minecraft", "Ninjabrain Bot", "Karabiner-Elements"])
    }
}
