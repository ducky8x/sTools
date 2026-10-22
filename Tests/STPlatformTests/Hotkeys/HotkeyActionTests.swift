import Foundation
import Testing
@testable import STPlatform

@Suite("HotkeyAction.resolve")
struct HotkeyResolveTests {
    private func changes(_ outcome: HotkeyOutcome) -> [String] {
        outcome.toolChanges.map { "\($0.tool.rawValue)=\($0.isOn)" }
    }

    @Test func allOffTurnsAllOn() {
        let outcome = HotkeyAction.resolve([.toggle(.crosshair), .toggle(.nbbOverlay)], toolStates: [:])
        #expect(changes(outcome) == ["crosshair=true", "nbbOverlay=true"])
        #expect(!outcome.togglesRecording)
    }

    @Test func allOnTurnsAllOff() {
        let states: [HotkeyTool: Bool] = [.crosshair: true, .nbbOverlay: true]
        let outcome = HotkeyAction.resolve([.toggle(.crosshair), .toggle(.nbbOverlay)], toolStates: states)
        #expect(changes(outcome) == ["crosshair=false", "nbbOverlay=false"])
    }

    @Test func mixedTurnsAllOn() {
        let states: [HotkeyTool: Bool] = [.crosshair: true, .nbbOverlay: false]
        let outcome = HotkeyAction.resolve([.toggle(.crosshair), .toggle(.nbbOverlay)], toolStates: states)
        #expect(changes(outcome) == ["crosshair=true", "nbbOverlay=true"])
    }

    @Test func mixedTurnsAllOnWhicheverToolIsOff() {
        let states: [HotkeyTool: Bool] = [.crosshair: false, .nbbOverlay: true]
        let outcome = HotkeyAction.resolve([.toggle(.crosshair), .toggle(.nbbOverlay)], toolStates: states)
        #expect(changes(outcome) == ["crosshair=true", "nbbOverlay=true"])
    }

    @Test func everyStateCombinationOfEveryToggledTool() {
        let tools = HotkeyTool.allCases
        let actions = tools.map(HotkeyAction.toggle)
        for mask in 0..<(1 << tools.count) {
            var states: [HotkeyTool: Bool] = [:]
            for (index, tool) in tools.enumerated() { states[tool] = mask & (1 << index) != 0 }
            let allOn = states.values.allSatisfy { $0 }
            let outcome = HotkeyAction.resolve(actions, toolStates: states)
            #expect(outcome.toolChanges.map(\.tool) == tools)
            #expect(outcome.toolChanges.allSatisfy { $0.isOn == !allOn }, "mask \(mask)")
        }
    }

    @Test func everySubsetOfToolsFollowsTheRule() {
        let tools = HotkeyTool.allCases
        for subsetMask in 1..<(1 << tools.count) {
            let subset = tools.enumerated().filter { subsetMask & (1 << $0.offset) != 0 }.map(\.element)
            for stateMask in 0..<(1 << tools.count) {
                var states: [HotkeyTool: Bool] = [:]
                for (index, tool) in tools.enumerated() { states[tool] = stateMask & (1 << index) != 0 }
                let anyOff = subset.contains { states[$0] == false }
                let outcome = HotkeyAction.resolve(subset.map(HotkeyAction.toggle), toolStates: states)
                #expect(outcome.toolChanges.allSatisfy { $0.isOn == anyOff }, "subset \(subsetMask) states \(stateMask)")
            }
        }
    }

    @Test func toolsOutsideTheSetAreNeverTouched() {
        let states: [HotkeyTool: Bool] = [.crosshair: true, .windowBackdrop: false]
        let outcome = HotkeyAction.resolve([.toggle(.crosshair)], toolStates: states)
        #expect(changes(outcome) == ["crosshair=false"])
    }

    @Test func recordingFlipsSeparatelyAndDoesNotInfluenceTools() {
        let alone = HotkeyAction.resolve([.startStopRecording], toolStates: [:])
        #expect(alone.toolChanges.isEmpty)
        #expect(alone.togglesRecording)

        let on: [HotkeyTool: Bool] = [.crosshair: true]
        let together = HotkeyAction.resolve([.toggle(.crosshair), .startStopRecording], toolStates: on)
        #expect(changes(together) == ["crosshair=false"])
        #expect(together.togglesRecording)
    }

    /// Screen Recording's one action has no toggle of its own: it starts or stops a recording on every press, and
    /// the tools beside it in the set follow the rule without it (spec 6.1).
    @Test func screenRecordingNeverTakesPartInTheToggleDecision() {
        for crosshairIsOn in [false, true] {
            let outcome = HotkeyAction.resolve([.startStopRecording, .toggle(.crosshair)], toolStates: [.crosshair: crosshairIsOn])
            #expect(changes(outcome) == ["crosshair=\(!crosshairIsOn)"])
            #expect(outcome.togglesRecording)
        }
    }

    @Test func emptySetDoesNothing() {
        let outcome = HotkeyAction.resolve([], toolStates: [.crosshair: true])
        #expect(outcome == HotkeyOutcome(toolChanges: [], togglesRecording: false))
        #expect(!outcome.startsTimer)
    }

    @Test func repeatedActionsCountOnce() {
        let outcome = HotkeyAction.resolve([.toggle(.crosshair), .toggle(.crosshair), .startStopRecording, .startStopRecording,
                                            .startTimer, .startTimer],
                                           toolStates: [:])
        #expect(changes(outcome) == ["crosshair=true"])
        #expect(outcome.togglesRecording)
        #expect(outcome.startsTimer)
    }

    @Test func startTimerActsOnItsOwn() {
        let alone = HotkeyAction.resolve([.startTimer], toolStates: [:])
        #expect(alone == HotkeyOutcome(toolChanges: [], togglesRecording: false, startsTimer: true))
        #expect(!HotkeyAction.resolve([.toggle(.crosshair), .startStopRecording], toolStates: [:]).startsTimer)
    }

    /// Timer Overlay has no toggle, so Start timer never counts as a tool that is off (spec 6.1).
    @Test func startTimerNeverTakesPartInTheToggleDecision() {
        let allOn: [HotkeyTool: Bool] = [.crosshair: true, .nbbOverlay: true]
        let outcome = HotkeyAction.resolve([.startTimer, .toggle(.crosshair), .toggle(.nbbOverlay), .startStopRecording],
                                           toolStates: allOn)
        #expect(changes(outcome) == ["crosshair=false", "nbbOverlay=false"])
        #expect(outcome.togglesRecording)
        #expect(outcome.startsTimer)
    }

    @Test func anOutcomeStartsNoTimerUnlessToldTo() {
        #expect(!HotkeyOutcome(toolChanges: [], togglesRecording: true).startsTimer)
        #expect(HotkeyOutcome(toolChanges: [], togglesRecording: false, startsTimer: true).startsTimer)
    }

    @Test func missingToolCountsAsOff() {
        let outcome = HotkeyAction.resolve([.toggle(.windowBackdrop), .toggle(.crosshair)], toolStates: [.crosshair: true])
        #expect(changes(outcome) == ["windowBackdrop=true", "crosshair=true"])
    }
}

@Suite("HotkeyAction")
struct HotkeyActionTests {
    @Test func uniquedKeepsFirstOccurrenceOrder() {
        let list: [HotkeyAction] = [.toggle(.crosshair), .startStopRecording, .toggle(.crosshair), .toggle(.nbbOverlay), .startStopRecording]
        #expect(list.uniqued == [.toggle(.crosshair), .startStopRecording, .toggle(.nbbOverlay)])
    }

    /// One chip per tool, in sidebar order: the three toggles, Start timer (Timer Overlay), then Screen Recording's one
    /// action. The key sets give the tools their keys in the same order.
    @Test func allCasesFollowTheSidebar() {
        #expect(HotkeyAction.allCases == [.toggle(.nbbOverlay), .toggle(.windowBackdrop), .toggle(.crosshair),
                                          .startTimer, .startStopRecording])
        #expect(HotkeyAction.allCases == HotkeyKeySet.toolActions)
    }

    @Test func storedAsPlainStrings() throws {
        let data = try JSONEncoder().encode([HotkeyAction.toggle(.windowBackdrop), .startStopRecording, .startTimer])
        #expect(String(decoding: data, as: UTF8.self) == #"["toggle.windowBackdrop","startStopRecording","startTimer"]"#)
        #expect(try JSONDecoder().decode([HotkeyAction].self, from: data) == [.toggle(.windowBackdrop), .startStopRecording, .startTimer])
    }

    @Test func everyActionRoundTrips() throws {
        let data = try JSONEncoder().encode(HotkeyAction.allCases)
        #expect(try JSONDecoder().decode([HotkeyAction].self, from: data) == HotkeyAction.allCases)
    }

    @Test func unknownActionFailsToDecode() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([HotkeyAction].self, from: Data(#"["toggle.hologram"]"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([HotkeyAction].self, from: Data(#"["explode"]"#.utf8)) }
    }
}

/// Screen Recording once had two actions, "Toggle Screen Recording" and "Start/stop recording"; hotkeys saved with
/// either keep working as the one action (spec 6.1).
@Suite("Screen Recording's one action")
struct ScreenRecordingActionTests {
    @Test func bothOldNamesReadAsTheOneAction() throws {
        let decoded = try JSONDecoder().decode([HotkeyAction].self, from: Data(#"["toggle.screenRecording","startStopRecording"]"#.utf8))
        #expect(decoded == [.startStopRecording, .startStopRecording])
        #expect(HotkeyTool(rawValue: "screenRecording") == nil)
    }

    /// Written under the name older builds read as Start/stop recording, so going back keeps the hotkey working.
    @Test func itIsWrittenUnderTheNameOlderBuildsRead() throws {
        let data = try JSONEncoder().encode([HotkeyAction.startStopRecording])
        #expect(String(decoding: data, as: UTF8.self) == #"["startStopRecording"]"#)
    }

    /// An existing `hotkeys.json` keeps working: a hotkey that had both actions keeps one Screen Recording action, one
    /// that had either with other actions keeps its place and its other actions, and two keys that each did one of
    /// them alone are one key now, the first (spec 6.1), so the list never has two Screen Recording keys.
    @MainActor
    @Test func anExistingHotkeysFileKeepsOneScreenRecordingAction() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stools-hotkeys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = """
            {"version":1,"value":{"isEnabled":true,"showsConfirmation":true,"bindings":[
             {"id":"00000000-0000-0000-0000-000000000001","combo":{"keyCode":96,"modifiers":0},
              "actions":["toggle.screenRecording","startStopRecording"]},
             {"id":"00000000-0000-0000-0000-000000000002","combo":{"keyCode":97,"modifiers":0},
              "actions":["toggle.screenRecording"]},
             {"id":"00000000-0000-0000-0000-000000000003","combo":{"keyCode":98,"modifiers":0},
              "actions":["toggle.crosshair","toggle.screenRecording","startTimer"]}]}}
            """
        try Data(file.utf8).write(to: directory.appending(path: "hotkeys.json"))
        let settings = SettingsStore(directory: directory).load(HotkeySettings.self)
        #expect(settings.isEnabled)
        #expect(settings.bindings.map(\.actions) == [
            [.startStopRecording],
            [.toggle(.crosshair), .startStopRecording, .startTimer],
        ])
        #expect(settings.bindings.map(\.id.uuidString) == ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000003"])
    }
}
