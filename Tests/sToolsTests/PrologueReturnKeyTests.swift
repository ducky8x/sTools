import AppKit
import Foundation
import Prologue
import STPlatform
import Testing
@testable import KeyRebinder
@testable import sTools

// The introduction's Key Rebinder trial draws the keyboard, which takes every key pressed in sTools' window and selects
// it on the plate. Return has to press Continue there as on every other step (spec 4.1, revision 43), but only once
// Continue is enabled: until the step is done Return goes to the drawn keyboard, as it always did. The page asks
// `KeyRebinderController.handle` what to do with each key; a key it doesn't use goes on to the window, whose default
// button is Continue. Nothing here shows a window or reads a real keyboard.

@MainActor
@Suite("Prologue ▸ Return on the Key Rebinder trial")
struct PrologueReturnKeyTests {
    private static let returnKey = KeyPress.down(.key("return_or_enter"), isRepeat: false)
    private static let keypadEnter = KeyPress.down(.key("keypad_enter"), isRepeat: false)
    private static let letterA = KeyPress.down(.key("a"), isRepeat: false)

    /// The trial on screen, over a Key Rebinder with a keyboard chosen (a laptop's unless told). The harness stays in the
    /// struct because the Prologue's model holds its host weakly.
    @MainActor
    private struct Trial {
        let harness: Harness
        let prologue: PrologueModel
        let keyRebinder: KeyRebinderController
        let content: TrialContent

        init(formFactor: KeyboardFormFactor = .laptop) throws {
            harness = Harness(prologueCompleted: false, withKeyRebinder: true)
            harness.model.beginPrologue(at: .keyRebinderTrial)
            prologue = try #require(harness.model.prologue)
            keyRebinder = try #require(harness.model.keyRebinder)
            keyRebinder.chooseLayout(shape: .ansi, formFactor: formFactor)
            content = harness.model.trialContent(.keyRebinder)
            content.onAppear()
        }

        /// Every item of the trial's checklist done: Continue is enabled.
        func finishTheTrial() {
            prologue.record(done: ["layout", "find", "tester"], items: content.items(), for: .keyRebinder)
        }

        /// What the page does with a key press: whether it's used (selected on the keyboard, swallowed) or left to the
        /// window.
        func pageUses(_ press: KeyPress) -> Bool {
            keyRebinder.handle(press, commandHeld: false, isBusy: false)
        }
    }

    // MARK: While Continue is grayed out

    @Test func returnGoesToTheDrawnKeyboardWhileContinueIsGrayedOut() throws {
        let trial = try Trial()
        #expect(!trial.prologue.canContinue)
        #expect(trial.pageUses(Self.returnKey))
        #expect(trial.keyRebinder.selectedKey == .key("return_or_enter"))
        trial.content.onDisappear()
    }

    // MARK: Once the step is done

    @Test func returnPressesContinueOnceTheStepIsDone() throws {
        let trial = try Trial()
        trial.finishTheTrial()
        #expect(trial.prologue.canContinue)
        trial.keyRebinder.selectedKey = nil
        #expect(!trial.pageUses(Self.returnKey), "the page leaves Return to the window, whose default button is Continue")
        #expect(trial.keyRebinder.selectedKey == nil, "and it doesn't select the Return key")
        trial.content.onDisappear()
    }

    @Test func everyOtherKeyStillSelectsItsKey() throws {
        let trial = try Trial(formFactor: .fullSize)
        trial.finishTheTrial()
        #expect(trial.pageUses(Self.letterA))
        #expect(trial.keyRebinder.selectedKey == .key("a"))
        #expect(trial.pageUses(Self.keypadEnter), "the keypad's Enter is a key of its own")
        #expect(trial.keyRebinder.selectedKey == .key("keypad_enter"))
        trial.content.onDisappear()
    }

    /// Continue follows the checklist live: Return changes hands as it turns on and off.
    @Test func returnFollowsContinueAsTheStepIsDoneAndSkipped() throws {
        let trial = try Trial()
        let items = trial.content.items()
        trial.prologue.record(done: ["layout", "find"], items: items, for: .keyRebinder)
        #expect(!trial.prologue.canContinue)
        #expect(trial.pageUses(Self.returnKey))
        trial.prologue.skipItem("tester", items: items, in: .keyRebinder)
        #expect(trial.prologue.canContinue)
        #expect(!trial.pageUses(Self.returnKey))
        trial.content.onDisappear()
    }

    /// Test keys still lights the Return key, but the press isn't swallowed once it can press Continue.
    @Test func theTesterLightsReturnAndLetsItThroughOnceTheStepIsDone() throws {
        let trial = try Trial()
        trial.keyRebinder.isTesting = true
        #expect(trial.pageUses(Self.returnKey), "grayed out: the tester takes every key")
        trial.finishTheTrial()
        #expect(!trial.pageUses(Self.returnKey))
        #expect(trial.keyRebinder.litKeys.contains(.key("return_or_enter")))
        trial.keyRebinder.isTesting = false
        trial.content.onDisappear()
    }

    /// Choosing an output by pressing it is waiting for exactly the next key, so it gets Return too.
    @Test func choosingAnOutputByPressingStillTakesReturn() throws {
        let trial = try Trial()
        trial.finishTheTrial()
        trial.keyRebinder.isCapturingOutput = true
        #expect(trial.pageUses(Self.returnKey))
        #expect(trial.keyRebinder.capturedOutput == .key("return_or_enter"))
        trial.keyRebinder.isCapturingOutput = false
        trial.content.onDisappear()
    }

    // MARK: Only the trial

    @Test func leavingTheTrialGivesReturnBackToTheKeyboard() throws {
        let trial = try Trial()
        trial.finishTheTrial()
        trial.content.onDisappear()
        #expect(trial.prologue.canContinue)
        trial.keyRebinder.selectedKey = nil
        #expect(trial.pageUses(Self.returnKey), "the Key Rebinder's own page always takes Return")
        #expect(trial.keyRebinder.selectedKey == .key("return_or_enter"))
    }

    @Test func theKeyRebinderPageTakesReturnWhenThereIsNoIntroduction() throws {
        let harness = Harness(withKeyRebinder: true)
        let keyRebinder = try #require(harness.model.keyRebinder)
        keyRebinder.chooseLayout(shape: .ansi, formFactor: .laptop)
        #expect(harness.model.prologue == nil)
        #expect(keyRebinder.handle(Self.returnKey, commandHeld: false, isBusy: false))
        #expect(keyRebinder.selectedKey == .key("return_or_enter"))
    }
}
