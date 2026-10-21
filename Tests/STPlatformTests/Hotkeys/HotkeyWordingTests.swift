import Foundation
import Testing
@testable import STPlatform

private let c = HotkeyCombo(keyCode: 8, modifiers: [])
private let shiftC = HotkeyCombo(keyCode: 8, modifiers: .shift)
private let controlC = HotkeyCombo(keyCode: 8, modifiers: .control)
private let commandC = HotkeyCombo(keyCode: 8, modifiers: .command)
private let controlOptionC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])
private let f5 = HotkeyCombo(keyCode: 96, modifiers: [])
private let controlF5 = HotkeyCombo(keyCode: 96, modifiers: .control)
private let shiftF5 = HotkeyCombo(keyCode: 96, modifiers: .shift)
private let f13 = HotkeyCombo(keyCode: 105, modifiers: [])
private let f18 = HotkeyCombo(keyCode: 79, modifiers: [])
private let help = HotkeyCombo(keyCode: 114, modifiers: [])
private let space = HotkeyCombo(keyCode: 49, modifiers: [])
private let pad1 = HotkeyCombo(keyCode: 83, modifiers: [])

@Suite("HotkeyWording")
struct HotkeyWordingTests {
    // MARK: Action titles

    @Test func todaysActionTitles() {
        #expect(HotkeyAction.toggle(.nbbOverlay).title == "NBB Overlay")
        #expect(HotkeyAction.toggle(.windowBackdrop).title == "Window Backdrop")
        #expect(HotkeyAction.toggle(.crosshair).title == "Crosshair")
        #expect(HotkeyAction.toggle(.screenRecording).title == "Screen Recording")
        #expect(HotkeyAction.startStopRecording.title == "Start/stop recording")
        #expect(HotkeyAction.startTimer.title == "Start timer")
    }

    /// Chips and summaries come from `allCases`, so every action, present or future, needs its own title.
    @Test func everyActionHasItsOwnTitle() {
        var seen: Set<String> = []
        for action in HotkeyAction.allCases {
            #expect(!action.title.isEmpty, "\(action)")
            #expect(seen.insert(action.title).inserted, "\(action) repeats \"\(action.title)\"")
        }
    }

    @Test func summaryJoinsWithPlusInActionOrder() {
        #expect(HotkeyWording.summary([.toggle(.crosshair), .toggle(.nbbOverlay)]) == "Crosshair + NBB Overlay")
        #expect(HotkeyWording.summary([.startStopRecording, .toggle(.crosshair)]) == "Start/stop recording + Crosshair")
        #expect(HotkeyWording.summary([.toggle(.windowBackdrop)]) == "Window Backdrop")
        #expect(HotkeyWording.summary([.toggle(.crosshair), .startTimer]) == "Crosshair + Start timer")
        #expect(HotkeyWording.summary([]) == "")
    }

    @Test func spokenSummaryReadsLikeASentence() {
        #expect(HotkeyWording.spokenSummary([.toggle(.crosshair)]) == "Crosshair")
        #expect(HotkeyWording.spokenSummary([.toggle(.crosshair), .toggle(.nbbOverlay)]) == "Crosshair and NBB Overlay")
        #expect(HotkeyWording.spokenSummary([.startTimer, .toggle(.crosshair)]) == "Start timer and Crosshair")
        #expect(HotkeyWording.spokenSummary([.toggle(.crosshair), .toggle(.nbbOverlay), .startStopRecording])
                == "Crosshair, NBB Overlay and Start/stop recording")
        #expect(HotkeyWording.spokenSummary([]) == "")
    }

    // MARK: Problems

    @Test func issueTexts() {
        #expect(HotkeyWording.issueText(.unsupportedKey) == "Unsupported key")
        #expect(HotkeyWording.issueText(.reserved("Spotlight")) == "Reserved: Spotlight")
    }

    @Test func conflictTextSaysAboveInTheList() {
        let owner = UUID()
        #expect(HotkeyWording.conflictText(.alreadyUsedByYou(owner), combo: controlOptionC, inList: true) == "Already used above")
        #expect(HotkeyWording.conflictText(.alreadyUsedByYou(owner), combo: controlOptionC, inList: false)
                == "Already used by another hotkey")
        #expect(HotkeyWording.conflictText(.noActions, combo: controlOptionC, inList: true) == "No actions")
        #expect(HotkeyWording.conflictText(.invalidCombo(.reserved("Quit")), combo: commandC, inList: false) == "Reserved: Quit")
    }

    /// macOS 15.0–15.1 reportedly refused hotkeys without ⌘ or ⌃; the refusal says so only for those.
    @Test func theRefusalHintNamesCommandAndControlOnlyWhenBothAreMissing() {
        #expect(HotkeyWording.conflictText(.systemRefused, combo: shiftC, inList: true)
                == "Refused by macOS. Some versions need ⌘ or ⌃.")
        #expect(HotkeyWording.conflictText(.systemRefused, combo: c, inList: false)
                == "Refused by macOS. Some versions need ⌘ or ⌃.")
        #expect(HotkeyWording.conflictText(.systemRefused, combo: controlOptionC, inList: true) == "Refused by macOS")
    }

    @Test func statusNoteIsNilForAHealthyOrUnknownHotkey() {
        #expect(HotkeyWording.statusNote(.registered, combo: c) == nil)
        #expect(HotkeyWording.statusNote(.inactive, combo: c) == nil)
        #expect(HotkeyWording.statusNote(nil, combo: c) == nil)
    }

    @Test func statusNoteSaysWhatIsWrong() {
        #expect(HotkeyWording.statusNote(.conflict(.noActions), combo: c) == "No actions")
        #expect(HotkeyWording.statusNote(.conflict(.alreadyUsedByYou(UUID())), combo: c) == "Already used above")
        #expect(HotkeyWording.statusNote(.conflict(.alreadyUsedByYou(UUID())), combo: c, inList: false)
                == "Already used by another hotkey")
        #expect(HotkeyWording.statusNote(.conflict(.systemRefused), combo: controlOptionC) == "Refused by macOS")
    }

    // MARK: Notes

    @Test func typingNoteOnlyForTypingKeysWithoutCommandOrControl() {
        for combo in [controlC, commandC, f5, shiftF5, f18, help] {
            #expect(HotkeyWording.typingNote(for: combo) == nil, "\(combo.displayString)")
        }
        for combo in [c, shiftC, space, pad1] {
            let note = HotkeyWording.typingNote(for: combo)
            #expect(note?.contains(combo.displayString) == true, "\(combo.displayString)")
            #expect(note?.contains("Minecraft") == true)
        }
        #expect(HotkeyWording.typingNote(for: c)
                == "While hotkeys are on, other apps never get C, not even Minecraft's chat or seed field.")
    }

    @Test func functionKeyNoteForF1ToF12() {
        #expect(HotkeyWording.functionKeyNote(for: f5) == "On a Mac keyboard you may need to hold fn with F5.")
        #expect(HotkeyWording.functionKeyNote(for: controlF5) == "On a Mac keyboard you may need to hold fn with F5.")
        #expect(HotkeyWording.functionKeyNote(for: HotkeyCombo(keyCode: 122, modifiers: [])) != nil) // F1
        #expect(HotkeyWording.functionKeyNote(for: HotkeyCombo(keyCode: 111, modifiers: [])) != nil) // F12
        #expect(HotkeyWording.functionKeyNote(for: f13) == nil)
        #expect(HotkeyWording.functionKeyNote(for: c) == nil)
    }

    // MARK: Spoken names

    @Test func spokenNames() {
        #expect(HotkeyWording.spokenName(for: HotkeyCombo(keyCode: 79, modifiers: .option)) == "Option F18")
        #expect(HotkeyWording.spokenName(for: pad1) == "Keypad 1")
        #expect(HotkeyWording.spokenName(for: HotkeyCombo(keyCode: 51, modifiers: [.control, .shift])) == "Control Shift Delete")
        #expect(HotkeyWording.spokenName(for: HotkeyCombo(keyCode: 8, modifiers: .all)) == "Control Option Shift Command C")
    }
}
